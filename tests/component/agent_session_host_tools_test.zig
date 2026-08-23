//! AgentCore Host sync tool vertical slice: Runtime registration -> Session
//! selection -> provider advertisement -> callback -> owned result release.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_STREAM_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_stream\",\"name\":\"HostStream\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const PLUGIN_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_plugin\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_plugin\",\"name\":\"acme_dreview__HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SERVICE_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_service\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_service\",\"name\":\"acme_dconsumer__HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const RELOAD_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_reload\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_reload\",\"name\":\"acme_dreload__HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Probe = struct {
    mode: enum { ok, fatal } = .ok,
    calls: usize = 0,
    releases: usize = 0,
    abort_session: ?*cc.agent_session.AgentSession = null,
    abort_run_id: u64 = 0,
    last_session_id: cc.session_id.SessionId = cc.session_id.SessionId.single,
    last_run_id: u64 = 0,
    last_host_ctx: ?*anyopaque = null,
    observed_session_ids: [4]cc.session_id.SessionId = .{cc.session_id.SessionId.single} ** 4,
    observed_run_ids: [4]u64 = .{0} ** 4,
    observed_host_ctxs: [4]?*anyopaque = .{null} ** 4,

    fn execute(raw: *anyopaque, identity: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        const self: *Probe = @ptrCast(@alignCast(raw));
        const call_index = self.calls;
        self.calls += 1;
        self.last_session_id = identity.identity.session_id;
        self.last_run_id = identity.identity.run_id;
        self.last_host_ctx = identity.host_session_ctx;
        if (call_index < self.observed_session_ids.len) {
            self.observed_session_ids[call_index] = identity.identity.session_id;
            self.observed_run_ids[call_index] = identity.identity.run_id;
            self.observed_host_ctxs[call_index] = identity.host_session_ctx;
        }
        if (self.mode == .fatal) return .fatal;
        if (self.abort_session) |session| session.abort(self.abort_run_id, .user_interrupt) catch return .fatal;
        return .{ .ok = .{ .bytes = "host-sync-ok", .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *Probe) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "HostEcho",
                .description = "Echo through the embedding Host",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{ .name = "text", .type = "string" }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
            .category = .execute,
        };
    }
};

const StreamProbe = struct {
    calls: usize = 0,
    writes: usize = 0,
    max_chunk_bytes: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: cc.agent_session.HostRunIdentity,
        _: []const u8,
        sink: *const cc.agent_session.HostResultSink,
    ) cc.agent_session.HostStreamExecuteError!cc.agent_session.HostStreamOutcome {
        const self: *StreamProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        var chunk: [64 * 1024]u8 = undefined;
        @memset(&chunk, 'v');
        var remaining: usize = 17 * 1024 * 1024 + 17;
        while (remaining != 0) {
            const count = @min(remaining, chunk.len);
            try sink.write(chunk[0..count]);
            self.writes += 1;
            self.max_chunk_bytes = @max(self.max_chunk_bytes, count);
            remaining -= count;
        }
        return .{ .artifact = .text_utf8 };
    }

    fn tool(self: *StreamProbe) cc.agent_session.HostStreamTool {
        return .{
            .definition = .{
                .name = "HostStream",
                .description = "Stream a large Host result without a full buffer",
                .input_schema = .{ .type = "object", .required = &.{} },
            },
            .ctx = self,
            .execute = execute,
        };
    }
};

const LifecycleProbe = struct {
    active: bool = false,
    activation_calls: usize = 0,
    tool_calls: usize = 0,
    releases: usize = 0,
    cleanup_order: [2]u8 = .{ 0, 0 },
    cleanup_count: usize = 0,

    fn activate(raw: *anyopaque, registrar: *cc.plugin.effect_scope.Registrar) cc.plugin.effect_scope.Error!void {
        const self: *LifecycleProbe = @ptrCast(@alignCast(raw));
        self.activation_calls += 1;
        self.active = true;
        try registrar.add("deactivate", raw, cleanupDeactivate);
        try registrar.add("release-resources", raw, cleanupResources);
    }

    fn cleanupDeactivate(raw: *anyopaque) void {
        const self: *LifecycleProbe = @ptrCast(@alignCast(raw));
        self.cleanup_order[self.cleanup_count] = 1;
        self.cleanup_count += 1;
        self.active = false;
    }

    fn cleanupResources(raw: *anyopaque) void {
        const self: *LifecycleProbe = @ptrCast(@alignCast(raw));
        self.cleanup_order[self.cleanup_count] = 2;
        self.cleanup_count += 1;
    }

    fn execute(raw: *anyopaque, _: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        const self: *LifecycleProbe = @ptrCast(@alignCast(raw));
        if (!self.active) return .fatal;
        self.tool_calls += 1;
        return .{ .ok = .{ .bytes = "lifecycle-tool-ok", .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *LifecycleProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *LifecycleProbe) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "HostEcho",
                .description = "Prove static plugin activation ownership",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{ .name = "text", .type = "string" }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
            .category = .execute,
        };
    }
};

const GenerationProbe = struct {
    result_bytes: []const u8,
    active: bool = false,
    calls: usize = 0,
    releases: usize = 0,
    cleanups: usize = 0,

    fn activate(raw: *anyopaque, registrar: *cc.plugin.effect_scope.Registrar) cc.plugin.effect_scope.Error!void {
        const self: *GenerationProbe = @ptrCast(@alignCast(raw));
        self.active = true;
        try registrar.add("generation", raw, cleanup);
    }

    fn cleanup(raw: *anyopaque) void {
        const self: *GenerationProbe = @ptrCast(@alignCast(raw));
        self.active = false;
        self.cleanups += 1;
    }

    fn execute(raw: *anyopaque, _: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        const self: *GenerationProbe = @ptrCast(@alignCast(raw));
        if (!self.active) return .fatal;
        self.calls += 1;
        return .{ .ok = .{ .bytes = self.result_bytes, .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *GenerationProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *GenerationProbe) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "HostEcho",
                .description = "Identify the immutable Runtime generation",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{ .name = "text", .type = "string" }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
            .category = .execute,
        };
    }
};

const AdvisoryProbe = struct {
    mode: enum { allow, deny, hide },
    tool_checks: usize = 0,
    invocation_checks: usize = 0,

    fn allowsTool(raw: *const anyopaque, _: []const u8) bool {
        const self: *AdvisoryProbe = @ptrCast(@alignCast(@constCast(raw)));
        self.tool_checks += 1;
        return self.mode != .hide;
    }

    fn allowsInvocation(raw: *const anyopaque, _: []const u8, _: []const u8) bool {
        const self: *AdvisoryProbe = @ptrCast(@alignCast(@constCast(raw)));
        self.invocation_checks += 1;
        return self.mode != .deny;
    }

    fn policy(self: *AdvisoryProbe) cc.agent_session.AdvisoryPolicy {
        return .{
            .ctx = self,
            .allowsToolFn = allowsTool,
            .allowsInvocationFn = allowsInvocation,
        };
    }
};

const GreetingService = struct {
    greeting: []const u8 = "service-graph-ok",
    active: bool = true,
    owner: ?*ServiceGraphProbe = null,
};

const ServiceGraphProbe = struct {
    service: GreetingService = .{},
    injected: ?*GreetingService = null,
    calls: usize = 0,
    releases: usize = 0,
    cleanup_order: [2]u8 = .{ 0, 0 },
    cleanup_count: usize = 0,

    fn activateProvider(raw: *anyopaque, registrar: *cc.plugin.effect_scope.Registrar) cc.plugin.effect_scope.Error!void {
        const self: *ServiceGraphProbe = @ptrCast(@alignCast(raw));
        try registrar.provide(GreetingService, "greeter", &self.service, cleanupService);
    }

    fn activateConsumer(raw: *anyopaque, registrar: *cc.plugin.effect_scope.Registrar) cc.plugin.effect_scope.Error!void {
        const self: *ServiceGraphProbe = @ptrCast(@alignCast(raw));
        self.injected = try registrar.require(GreetingService, "acme.provider", "greeter");
        try registrar.add("consumer", raw, cleanupConsumer);
    }

    fn cleanupConsumer(raw: *anyopaque) void {
        const self: *ServiceGraphProbe = @ptrCast(@alignCast(raw));
        self.cleanup_order[self.cleanup_count] = 2;
        self.cleanup_count += 1;
        self.injected = null;
    }

    fn cleanupService(raw: *anyopaque) void {
        const service: *GreetingService = @ptrCast(@alignCast(raw));
        service.active = false;
        const self = service.owner.?;
        self.cleanup_order[self.cleanup_count] = 1;
        self.cleanup_count += 1;
    }

    fn execute(raw: *anyopaque, _: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        const self: *ServiceGraphProbe = @ptrCast(@alignCast(raw));
        const service = self.injected orelse return .fatal;
        if (!service.active) return .fatal;
        self.calls += 1;
        return .{ .ok = .{ .bytes = service.greeting, .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *ServiceGraphProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *ServiceGraphProbe, name: []const u8) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = name,
                .description = "Consume an activation-injected typed service",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{ .name = "text", .type = "string" }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
            .category = .execute,
        };
    }
};

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "L2 selected Host sync tool is advertised, executed and released exactly once" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = Probe{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "call the host", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    try std.testing.expectEqualStrings(session.session_id.asSlice(), probe.last_session_id.asSlice());
    try std.testing.expectEqual(@as(u64, 1), probe.last_run_id);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&probe)), probe.last_host_ctx);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "HostEcho") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "host-sync-ok") != null);
}

test "L2 selected Host stream tool publishes a recoverable envelope without request amplification" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_STREAM_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = StreamProbe{};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .host_stream_tools = &.{probe.tool()},
    });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .home = root },
        .artifact_store = .{ .exact_root = root },
        .allowed_tools = &.{"HostStream"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "stream the host result", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.writes > 1);
    try std.testing.expectEqual(@as(usize, 64 * 1024), probe.max_chunk_bytes);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(body.len < 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, body, cc.tool_result.PROJECTION_SCHEMA) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ReadArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "17825809") != null);
}

test "L2 Host stream selection fails admission when artifact storage is disabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var probe = StreamProbe{};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .host_stream_tools = &.{probe.tool()},
    });
    defer runtime.destroy() catch unreachable;
    try std.testing.expectError(error.ArtifactStoreRequired, runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostStream"},
        .host_identity_ctx = &probe,
    }));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "L2 static plugin is namespaced advertised guarded dispatched and attributed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ PLUGIN_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = Probe{};
    const plugin_id = try cc.plugin.contract.PluginId.parse("acme.review");
    const plugin_version = try cc.plugin.contract.Version.parse("1.0.0");
    const plugin_caps = cc.plugin.contract.CapabilitySet.from(&.{.host_tool});
    const static_plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = plugin_id,
            .version = plugin_version,
            .form = .static_trusted,
            .capabilities = plugin_caps,
        },
        .tools = &.{probe.tool()},
    }};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &static_plugins,
    });
    defer runtime.destroy() catch unreachable;
    const record = runtime.plugin_snapshot.find("acme.review") orelse return error.PluginMissing;
    try std.testing.expectEqual(@as(usize, 1), record.contribution_count);
    try std.testing.expectEqual(cc.plugin.contract.LifecycleState.active, record.lifecycle);
    const inventory_json = try runtime.describePlugins(allocator);
    defer allocator.free(inventory_json);
    var inventory = try std.json.parseFromSlice(std.json.Value, allocator, inventory_json, .{});
    defer inventory.deinit();
    try std.testing.expectEqualStrings(
        "acme.review",
        inventory.value.object.get("plugins").?.array.items[0].object.get("id").?.string,
    );
    try std.testing.expectEqualStrings(
        "static_trusted",
        inventory.value.object.get("plugins").?.array.items[0].object.get("form").?.string,
    );

    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreview__HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "call plugin tool", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "acme_dreview__HostEcho") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "host-sync-ok") != null);
}

test "L2 plugin effect lifecycle owns tool state until the last Session exits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ PLUGIN_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = LifecycleProbe{};
    const plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.review"),
            .version = try cc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        },
        .tools = &.{probe.tool()},
        .activation = .{ .ctx = &probe, .activate = LifecycleProbe.activate },
    }};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &plugins,
    });
    var runtime_alive = true;
    defer if (runtime_alive) runtime.destroy() catch unreachable;
    try std.testing.expect(probe.active);
    try std.testing.expectEqual(@as(usize, 1), probe.activation_calls);

    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreview__HostEcho"},
        .host_identity_ctx = &probe,
    });
    var session_alive = true;
    defer if (session_alive) session.destroy() catch unreachable;

    try std.testing.expectError(error.RuntimeBusy, runtime.destroy());
    try std.testing.expect(probe.active);
    try std.testing.expectEqual(@as(usize, 0), probe.cleanup_count);

    var sink_state: u8 = 0;
    const result = try session.runText(1, "call activated plugin", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);

    try session.destroy();
    session_alive = false;
    try runtime.destroy();
    runtime_alive = false;
    try std.testing.expect(!probe.active);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, &probe.cleanup_order);
    try std.testing.expectEqual(@as(usize, 2), probe.cleanup_count);
}

test "L2 plugin service graph injects a declared dependency into a real Host tool" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ SERVICE_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = ServiceGraphProbe{};
    probe.service.owner = &probe;
    const version = try cc.plugin.contract.Version.parse("1.0.0");
    const provider_id = try cc.plugin.contract.PluginId.parse("acme.provider");
    const dependencies = [_]cc.plugin.contract.Dependency{.{
        .id = provider_id,
        .minimum = version,
    }};
    const plugins = [_]cc.agent_session.StaticPlugin{
        .{
            .descriptor = .{
                .id = try cc.plugin.contract.PluginId.parse("acme.consumer"),
                .version = version,
                .form = .static_trusted,
                .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
                .dependencies = &dependencies,
            },
            .tools = &.{probe.tool("HostEcho")},
            .activation = .{ .ctx = &probe, .activate = ServiceGraphProbe.activateConsumer },
        },
        .{
            .descriptor = .{
                .id = provider_id,
                .version = version,
                .form = .static_trusted,
                .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.service}),
            },
            .activation = .{ .ctx = &probe, .activate = ServiceGraphProbe.activateProvider },
        },
    };
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &plugins,
    });
    var runtime_alive = true;
    defer if (runtime_alive) runtime.destroy() catch unreachable;
    try std.testing.expect(probe.injected != null);
    try std.testing.expect(probe.service.active);
    const provider_record = runtime.plugin_snapshot.find("acme.provider") orelse return error.PluginMissing;
    try std.testing.expect(provider_record.descriptor.capabilities.contains(.service));
    try std.testing.expectEqual(@as(usize, 1), provider_record.contribution_count);

    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dconsumer__HostEcho"},
        .host_identity_ctx = &probe,
    });
    var session_alive = true;
    defer if (session_alive) session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "call the service consumer", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "service-graph-ok") != null);

    try session.destroy();
    session_alive = false;
    try runtime.destroy();
    runtime_alive = false;
    try std.testing.expect(!probe.service.active);
    try std.testing.expect(probe.injected == null);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, &probe.cleanup_order);
}

test "L2 static advisory hook denies before dispatch through the native policy pipeline" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ PLUGIN_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var tool_probe = Probe{};
    var advisory_probe = AdvisoryProbe{ .mode = .deny };
    var facade_probe = AdvisoryProbe{ .mode = .allow };
    const plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.review"),
            .version = try cc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{ .host_tool, .advisory_hook }),
        },
        .tools = &.{tool_probe.tool()},
        .advisory_policy = advisory_probe.policy(),
    }};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &plugins,
    });
    defer runtime.destroy() catch unreachable;
    const record = runtime.plugin_snapshot.find("acme.review") orelse return error.PluginMissing;
    try std.testing.expectEqual(@as(usize, 2), record.contribution_count);

    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreview__HostEcho"},
        .host_identity_ctx = &tool_probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    var admitted = try session.admitRun(1, .{ .ctx = &sink_state, .emit = Sink.emit });
    const result = try admitted.runUserMessagesWithPolicy(
        &.{"attempt plugin call"},
        4,
        facade_probe.policy(),
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expect(advisory_probe.tool_checks > 0);
    try std.testing.expect(advisory_probe.invocation_checks > 0);
    try std.testing.expect(facade_probe.tool_checks > 0);
    try std.testing.expectEqual(@as(usize, 0), tool_probe.calls);
    try std.testing.expectEqual(@as(usize, 0), tool_probe.releases);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "outside the current execution policy") != null);
}

test "L2 static advisory hook hides a tool from the provider schema" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.start(FINAL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var tool_probe = Probe{};
    var advisory_probe = AdvisoryProbe{ .mode = .hide };
    const plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.review"),
            .version = try cc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{ .host_tool, .advisory_hook }),
        },
        .tools = &.{tool_probe.tool()},
        .advisory_policy = advisory_probe.policy(),
    }};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &plugins,
    });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreview__HostEcho"},
        .host_identity_ctx = &tool_probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "answer without tools", 2, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expect(advisory_probe.tool_checks > 0);
    try std.testing.expectEqual(@as(usize, 0), advisory_probe.invocation_checks);
    try std.testing.expectEqual(@as(usize, 0), tool_probe.calls);
    const body = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "acme_dreview__HostEcho") == null);
}

test "L2 RuntimeHost atomically replaces plugin generations and drains pinned Sessions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const old_bodies = [_][]const u8{ RELOAD_TOOL_SSE, FINAL_SSE };
    const new_bodies = [_][]const u8{ RELOAD_TOOL_SSE, FINAL_SSE };
    var old_server = try harness.MockServer.startCassette(&old_bodies, 0);
    defer old_server.stop();
    var new_server = try harness.MockServer.startCassette(&new_bodies, 0);
    defer new_server.stop();
    const old_url = try old_server.urlOwned(allocator);
    defer allocator.free(old_url);
    const new_url = try new_server.urlOwned(allocator);
    defer allocator.free(new_url);

    const version = try cc.plugin.contract.Version.parse("1.0.0");
    const plugin_id = try cc.plugin.contract.PluginId.parse("acme.reload");
    var old_probe = GenerationProbe{ .result_bytes = "generation-old" };
    const old_plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = plugin_id,
            .version = version,
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        },
        .tools = &.{old_probe.tool()},
        .activation = .{ .ctx = &old_probe, .activate = GenerationProbe.activate },
    }};
    const host = try cc.agent_session.RuntimeHost.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &old_plugins,
    });
    var host_alive = true;
    defer if (host_alive) host.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(try host.generation()));
    try std.testing.expect(old_probe.active);

    const old_session = try host.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = old_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreload__HostEcho"},
        .host_identity_ctx = &old_probe,
    });
    var old_session_alive = true;
    defer if (old_session_alive) old_session.destroy() catch unreachable;

    const invalid_plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.invalid-service"),
            .version = version,
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.service}),
        },
    }};
    try std.testing.expectError(error.UnsupportedContribution, host.replace(.{
        .builtin_tools = &.{},
        .static_plugins = &invalid_plugins,
    }));
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(try host.generation()));
    try std.testing.expect(old_probe.active);
    try std.testing.expectEqual(@as(usize, 0), old_probe.cleanups);

    var new_probe = GenerationProbe{ .result_bytes = "generation-new" };
    const new_plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = plugin_id,
            .version = version,
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        },
        .tools = &.{new_probe.tool()},
        .activation = .{ .ctx = &new_probe, .activate = GenerationProbe.activate },
    }};
    const published = try host.replace(.{
        .builtin_tools = &.{},
        .static_plugins = &new_plugins,
    });
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(published));
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(try host.generation()));
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(old_session.pluginGeneration()));
    try std.testing.expect(old_probe.active);
    try std.testing.expect(new_probe.active);

    const new_session = try host.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = new_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreload__HostEcho"},
        .host_identity_ctx = &new_probe,
    });
    var new_session_alive = true;
    defer if (new_session_alive) new_session.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(new_session.pluginGeneration()));

    var sink_state: u8 = 0;
    const old_result = try old_session.runText(1, "call old generation", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    const new_result = try new_session.runText(1, "call new generation", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, old_result.stop_reason);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, new_result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), old_probe.calls);
    try std.testing.expectEqual(@as(usize, 1), old_probe.releases);
    try std.testing.expectEqual(@as(usize, 1), new_probe.calls);
    try std.testing.expectEqual(@as(usize, 1), new_probe.releases);
    const old_body = (old_server.lastRequest() orelse return error.NoRequestCaptured).body();
    const new_body = (new_server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, old_body, "generation-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_body, "generation-new") != null);

    try old_session.destroy();
    old_session_alive = false;
    try std.testing.expect(!old_probe.active);
    try std.testing.expectEqual(@as(usize, 1), old_probe.cleanups);
    try std.testing.expect(new_probe.active);

    try host.destroy();
    host_alive = false;
    try std.testing.expect(new_probe.active);
    try std.testing.expectEqual(@as(usize, 0), new_probe.cleanups);

    try new_session.destroy();
    new_session_alive = false;
    try std.testing.expect(!new_probe.active);
    try std.testing.expectEqual(@as(usize, 1), new_probe.cleanups);
}

test "L2 static plugin cannot bypass the native plan-mode guard" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ PLUGIN_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = Probe{};
    var advisory_probe = AdvisoryProbe{ .mode = .allow };
    const plugins = [_]cc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.review"),
            .version = try cc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{ .host_tool, .advisory_hook }),
        },
        .tools = &.{probe.tool()},
        .advisory_policy = advisory_probe.policy(),
    }};
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{
        .builtin_tools = &.{},
        .static_plugins = &plugins,
    });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .plan,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"acme_dreview__HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    _ = try session.runText(1, "attempt plugin mutation", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    try std.testing.expect(advisory_probe.tool_checks > 0);
    try std.testing.expectEqual(@as(usize, 0), advisory_probe.invocation_checks);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "denied by permission rule or plan mode") != null);
}

test "L2 Host identity is admission-fixed across two Runs and distinct across two Sessions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{
        HOST_TOOL_SSE,
        FINAL_SSE,
        HOST_TOOL_SSE,
        FINAL_SSE,
        HOST_TOOL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = Probe{};
    var anchor_a: u8 = 1;
    var anchor_b: u8 = 2;
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session_a = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &anchor_a,
    });
    defer session_a.destroy() catch unreachable;
    const session_b = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &anchor_b,
    });
    defer session_b.destroy() catch unreachable;

    var sink_state: u8 = 0;
    _ = try session_a.runText(10, "first A run", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    _ = try session_a.runText(11, "second A run", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    _ = try session_b.runText(20, "first B run", 4, .{ .ctx = &sink_state, .emit = Sink.emit });

    try std.testing.expectEqual(@as(usize, 3), probe.calls);
    try std.testing.expectEqual(@as(usize, 3), probe.releases);
    try std.testing.expectEqualStrings(session_a.session_id.asSlice(), probe.observed_session_ids[0].asSlice());
    try std.testing.expectEqualStrings(session_a.session_id.asSlice(), probe.observed_session_ids[1].asSlice());
    try std.testing.expectEqualStrings(session_b.session_id.asSlice(), probe.observed_session_ids[2].asSlice());
    try std.testing.expect(!std.mem.eql(u8, probe.observed_session_ids[0].asSlice(), probe.observed_session_ids[2].asSlice()));
    try std.testing.expectEqualSlices(u64, &.{ 10, 11, 20 }, probe.observed_run_ids[0..3]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&anchor_a)), probe.observed_host_ctxs[0]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&anchor_a)), probe.observed_host_ctxs[1]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&anchor_b)), probe.observed_host_ctxs[2]);
}

test "L2 unadvertised Host tool is rejected without invoking callback" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = Probe{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{},
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    _ = try session.runText(1, "do not trust provider output", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "unknown_tool") != null);
}

test "L2 Host sync callback may reenter abort without lifecycle deadlock" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{HOST_TOOL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = Probe{ .abort_run_id = 7 };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;
    probe.abort_session = session;

    var sink_state: u8 = 0;
    const result = try session.runText(7, "abort from callback", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.aborted, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
}

test "L2 Host fatal poisons the Session and maps to CallbackFailed without a tool result turn" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.start(HOST_TOOL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = Probe{ .mode = .fatal };
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    try std.testing.expectError(
        error.CallbackFailed,
        session.runText(11, "fatal host callback", 4, .{ .ctx = &sink_state, .emit = Sink.emit }),
    );
    try std.testing.expect(session.isPoisoned());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    try std.testing.expectError(
        error.InvalidSessionState,
        session.runText(12, "must stay poisoned", 1, .{ .ctx = &sink_state, .emit = Sink.emit }),
    );
}
