//! L2 plugin proof: external strict manifest -> immutable plugin snapshot ->
//! canonical Skill Runtime -> model-visible tool schema in a real request.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const REQUIRED_FIRST_READ_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"ignored.txt\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const REQUIRED_FIRST_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"verify-change\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn realRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

fn createPackage(root: []const u8, manifest_bytes: []const u8, skill_body: ?[]const u8) !void {
    const meta = try std.fmt.allocPrint(std.testing.allocator, "{s}/.metacodes-plugin", .{root});
    defer std.testing.allocator.free(meta);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, meta);
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plugin.json", .{meta});
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest_bytes });
    if (skill_body) |body| {
        const skill_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/skills/review", .{root});
        defer std.testing.allocator.free(skill_dir);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, skill_dir);
        const skill_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{skill_dir});
        defer std.testing.allocator.free(skill_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = skill_path, .data = body });
    }
}

fn createAgent(root: []const u8, body: []const u8) !void {
    const agent_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/agents", .{root});
    defer std.testing.allocator.free(agent_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, agent_dir);
    const agent_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/reviewer.md", .{agent_dir});
    defer std.testing.allocator.free(agent_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = agent_path, .data = body });
}

const ActivationOrderProbe = struct {
    events: [4]u8 = .{ 0, 0, 0, 0 },
    count: usize = 0,

    const Context = struct {
        probe: *ActivationOrderProbe,
        activation_event: u8,
        cleanup_event: u8,
        fail: bool = false,
    };

    fn push(self: *ActivationOrderProbe, event: u8) void {
        self.events[self.count] = event;
        self.count += 1;
    }

    fn activate(raw: *anyopaque, registrar: *cc.plugin.effect_scope.Registrar) cc.plugin.effect_scope.Error!void {
        const context: *Context = @ptrCast(@alignCast(raw));
        context.probe.push(context.activation_event);
        try registrar.add("activation", raw, cleanup);
        if (context.fail) return error.PluginActivationFailed;
    }

    fn cleanup(raw: *anyopaque) void {
        const context: *Context = @ptrCast(@alignCast(raw));
        context.probe.push(context.cleanup_event);
    }

    fn execute(_: *anyopaque, _: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        return .fatal;
    }

    fn tool(context: *Context) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "Probe",
                .description = "Activation-order probe",
                .input_schema = .{ .type = "object" },
            },
            .ctx = context,
            .execute = execute,
            .category = .execute,
        };
    }
};

const PolicyFilter = struct {
    denied_name: []const u8,

    fn allowsTool(raw: *const anyopaque, name: []const u8) bool {
        const self: *const PolicyFilter = @ptrCast(@alignCast(raw));
        return !std.mem.eql(u8, self.denied_name, name);
    }

    fn allowsInvocation(raw: *const anyopaque, name: []const u8, _: []const u8) bool {
        return allowsTool(raw, name);
    }

    fn policy(self: *const PolicyFilter) cc.agent_session.AdvisoryPolicy {
        return .{
            .ctx = self,
            .allowsToolFn = allowsTool,
            .allowsInvocationFn = allowsInvocation,
        };
    }
};

const RequiredFirstProbe = struct {
    skill_calls: usize = 0,
    other_calls: usize = 0,

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const cc.tools.ToolContext,
        name: []const u8,
        _: []const u8,
    ) anyerror!cc.tools.ToolDispatchOutcome {
        const self: *RequiredFirstProbe = @ptrCast(@alignCast(@constCast(raw)));
        if (std.mem.eql(u8, name, "Skill")) {
            self.skill_calls += 1;
            return .{ .ok = cc.tools.ToolResultBody.initInline(try tool_ctx.allocator.dupe(u8, "activated")) };
        }
        self.other_calls += 1;
        return .{ .ok = cc.tools.ToolResultBody.initInline(try tool_ctx.allocator.dupe(u8, "unexpected")) };
    }

    fn metadata(_: *const anyopaque, _: []const u8) ?cc.tools.ToolMeta {
        return .{ .kind = .external, .category = .execute, .replay = .never, .prefetch_safe = false };
    }

    fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
        return switch (index) {
            0 => "Skill",
            1 => "Read",
            else => null,
        };
    }

    fn dispatcher(self: *RequiredFirstProbe) cc.tools.ToolDispatcher {
        return .{
            .ctx = @ptrCast(self),
            .dispatchFn = dispatch,
            .metadataFn = metadata,
            .nameAtFn = nameAt,
        };
    }
};

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
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

test "L2 repeatable --plugin-dir is a fail-closed external configuration contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][*:0]const u8{
        "metacodes",
        "--plugin-dir",
        "plugins/one",
        "--plugin-dir",
        "plugins/two",
        "--dump-plugins",
    };
    const config = cc.parseArgsForTest(&argv, arena.allocator());
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqualStrings("plugins/one\x00plugins/two", config.plugin_dirs.?);
    try std.testing.expect(config.dump_plugins);

    const missing = [_][*:0]const u8{ "metacodes", "--plugin-dir" };
    const invalid = cc.parseArgsForTest(&missing, arena.allocator());
    try std.testing.expect(invalid.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid.parse_error.?, "missing value for --plugin-dir") != null);
}

test "L2 CLI plugin package reaches App canonical Skill Agent and provider request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    try createPackage(
        root,
        "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.2.0\",\"capabilities\":[\"skill_bundle\",\"agent_bundle\"]}",
        "---\nname: review\ndescription: APP_PLUGIN_SKILL_DESCRIPTION\nmodel-activation: required-first\n---\nAPP_PLUGIN_SKILL_BODY\n",
    );
    try createAgent(
        root,
        "---\nname: reviewer\ndescription: APP_PLUGIN_AGENT_DESCRIPTION\nskills: review\n---\nAPP_PLUGIN_AGENT_PROMPT\n",
    );

    var server = try harness.MockServer.start(END_TURN_SSE, 0);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const url = try server.urlOwned(allocator);
    const root_z = try allocator.dupeZ(u8, root);
    const url_z = try allocator.dupeZ(u8, url);
    const argv = [_][*:0]const u8{
        "metacodes",
        "--plugin-dir",
        root_z.ptr,
        "--base-url",
        url_z.ptr,
        "--model",
        "glm-5.2",
        "--permission",
        "bypassPermissions",
    };
    var config = cc.parseArgsForTest(&argv, allocator);
    try std.testing.expect(config.parse_error == null);
    config.long_horizon_arm = .codex_style;

    const home_z = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}", .{root}, 0);
    defer std.testing.allocator.free(home_z);
    var home_guard = try EnvGuard.set(std.testing.allocator, "HOME", home_z.ptr);
    defer home_guard.restore();
    var probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
    defer probe_guard.restore();

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    const app = try cc.app_module.App.init(allocator, io_runtime.io(), config, "test-key");
    defer app.deinit();

    try std.testing.expect(app.plugin_snapshot != null);
    const inventory_json = try app.describePlugins(allocator);
    defer allocator.free(inventory_json);
    var inventory = try std.json.parseFromSlice(std.json.Value, allocator, inventory_json, .{});
    defer inventory.deinit();
    try std.testing.expectEqualStrings(
        "metacodes.plugin-inventory/v1",
        inventory.value.object.get("schema").?.string,
    );
    try std.testing.expectEqualStrings(
        "acme.review",
        inventory.value.object.get("plugins").?.array.items[0].object.get("id").?.string,
    );
    try std.testing.expectEqualStrings(
        "1.2.0",
        inventory.value.object.get("plugins").?.array.items[0].object.get("version").?.string,
    );
    try std.testing.expect(app.skill_runtime.findRecord("acme_dreview:review") != null);
    const plugin_agent = app.agents.find("acme_dreview:reviewer") orelse return error.PluginAgentMissing;
    try std.testing.expectEqual(cc.agents_def.Origin.plugin, plugin_agent.origin);
    try std.testing.expectEqualStrings("acme_dreview:review", plugin_agent.preload_skills[0]);
    try std.testing.expect(std.mem.indexOf(u8, app.system_prompt orelse "", "APP_PLUGIN_AGENT_DESCRIPTION") != null);

    try app.conversation.appendText(.user, "inspect using the configured plugin");
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    _ = try cc.agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        .{ .max_turns = 1, .system_prompt = app.system_prompt },
        &backend,
        allocator,
    );

    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "acme_dreview:review") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "APP_PLUGIN_SKILL_DESCRIPTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`acme_dreview:review`") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"tool_choice\":{\"type\":\"tool\",\"name\":\"Skill\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "acme_dreview:reviewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "APP_PLUGIN_AGENT_DESCRIPTION") != null);
}

test "L2 external plugin manifest changes canonical Skill schema sent to provider" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    try createPackage(
        root,
        "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.2.0\",\"capabilities\":[\"skill_bundle\"]}",
        "---\nname: review\ndescription: PLUGIN_REVIEW_DESCRIPTION\nmodel-activation: required-first\n---\nPLUGIN_REVIEW_BODY\n",
    );

    const snapshot = try cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(7),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.skill_bundle}),
        .packages = &.{.{ .root = root, .layer = .project }},
    });
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(usize, 1), snapshot.plugins.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.skill_sources.len);
    try std.testing.expectEqualStrings("acme_dreview", snapshot.skill_sources[0].namespace);
    try std.testing.expectEqual(@as(usize, 1), snapshot.plugins[0].contribution_count);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var skill_runtime = cc.skills_cli_adapter.Runtime.init(allocator, io_runtime.io());
    defer skill_runtime.deinit();
    var projection = cc.skills.SkillSet.init(allocator);
    defer projection.deinit();
    try skill_runtime.loadSources(root, "", "plugin-generation-7", snapshot.skill_sources, &projection);
    try std.testing.expect(skill_runtime.findRecord("acme_dreview:review") != null);

    var registry = cc.tools_dynamic.DynRegistry.init(allocator);
    defer registry.deinit();
    try cc.skills_tool.registerSkillTool(&registry, &skill_runtime);
    var definitions_arena = std.heap.ArenaAllocator.init(allocator);
    defer definitions_arena.deinit();
    const definitions = try cc.tools.toToolDefinitionsWithDyn(definitions_arena.allocator(), &registry);
    try std.testing.expect(skill_runtime.applyModelToolSchema(definitions));

    var server = try harness.MockServer.start(END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "test-key", "glm-5.2", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "use the plugin if relevant");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    _ = try cc.agent_loop.run(&conversation, client.provider(), definitions, &permission, .{
        .max_turns = 1,
        .system_prompt = "plugin-l2",
    }, &backend, allocator);

    const request = server.lastRequest() orelse return error.NoRequestCaptured;
    const body = request.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "acme_dreview:review") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "PLUGIN_REVIEW_DESCRIPTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`acme_dreview:review`") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "\"tool_choice\":{\"type\":\"tool\",\"name\":\"Skill\"}",
    ) != null);
}

test "L2 required-first survives an ignoring GLM gateway and blocks earlier tools" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{
        END_TURN_SSE,
        REQUIRED_FIRST_READ_SSE,
        REQUIRED_FIRST_SKILL_SSE,
        END_TURN_SSE,
    };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "glm-5.2",
        url,
    );
    defer client.deinit();

    const definitions = [_]cc.json_mod.ToolDefinition{
        .{
            .name = "Skill",
            .description = "activate the exact bound Skill",
            .input_schema = .{ .type = "object", .prop_specs = &.{
                .{ .name = "name", .type = "string" },
            }, .required = &.{"name"} },
            .model_activation = .{
                .mode = .required_first,
                .argument_name = "name",
                .argument_value = "verify-change",
            },
        },
        .{
            .name = "Read",
            .description = "must remain blocked until activation",
            .input_schema = .{ .type = "object" },
        },
    };
    var probe = RequiredFirstProbe{};
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "make the requested change");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        &definitions,
        &permission,
        .{
            .max_turns = 6,
            .system_prompt = "base",
            .tool_dispatcher = probe.dispatcher(),
        },
        &backend,
        allocator,
    );

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.skill_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.other_calls);
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());

    const forced = "\"tool_choice\":{\"type\":\"tool\",\"name\":\"Skill\"}";
    const first = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    const repaired = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    const denied = (server.requestAt(2) orelse return error.NoRequestCaptured).body();
    const released = (server.requestAt(3) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, first, forced) != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired, forced) != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "Required-first activation is still pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied, forced) != null);
    try std.testing.expect(std.mem.indexOf(u8, denied, "required_first_pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, released, "\"tool_choice\"") == null);
}

test "L2 required-first satisfaction survives compact boundary without schema cache drift" {
    const allocator = std.testing.allocator;
    var server = try harness.MockServer.start(END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "glm-5.2",
        url,
    );
    defer client.deinit();

    const skill = cc.json_mod.ToolDefinition{
        .name = "Skill",
        .description = "cache-stable activation tool",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "name", .type = "string" },
        }, .required = &.{"name"} },
        .model_activation = .{
            .mode = .required_first,
            .argument_name = "name",
            .argument_value = "verify-change",
        },
    };
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "original request");

    const use_blocks = try allocator.alloc(cc.message.Block, 1);
    use_blocks[0] = .{ .tool_use = .{
        .id = try allocator.dupe(u8, "skill_compacted"),
        .name = try allocator.dupe(u8, "Skill"),
        .input = try allocator.dupe(u8, "{\"name\":\"verify-change\"}"),
    } };
    try conversation.append(.{ .role = .assistant, .blocks = use_blocks });

    const result_blocks = try allocator.alloc(cc.message.Block, 1);
    result_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try allocator.dupe(u8, "skill_compacted"),
        .content = try allocator.dupe(u8, "activated"),
    } };
    try conversation.append(.{ .role = .user, .blocks = result_blocks });
    try conversation.appendText(.user, "continue after compact");
    try conversation.restoreCompactState(3, "summary without a trusted activation marker");

    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const run_result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        &.{skill},
        &permission,
        .{ .max_turns = 1, .system_prompt = "cache-prefix" },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run_result.stop_reason);

    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "blocking requirement") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "cache-stable activation tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "skill_compacted") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "continue after compact") != null);
}

test "external plugin loader fails closed on symlinked manifest" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const meta = try std.fmt.allocPrint(allocator, "{s}/.metacodes-plugin", .{root});
    defer allocator.free(meta);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, meta);
    const target = try std.fmt.allocPrint(allocator, "{s}/real.json", .{root});
    defer allocator.free(target);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = target,
        .data = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"skill_bundle\"]}",
    });
    const link = try std.fmt.allocPrintSentinel(allocator, "{s}/plugin.json", .{meta}, 0);
    defer allocator.free(link);
    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    if (std.c.symlink(target_z.ptr, link.ptr) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.PackageManifestUntrusted, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.skill_bundle}),
        .packages = &.{.{ .root = root, .layer = .project }},
    }));
}

test "external plugin dependency and Host capability negotiation fail before publish" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    try createPackage(
        root,
        "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"skill_bundle\"],\"requires\":[{\"id\":\"acme.base\",\"minimum_version\":\"1.0.0\"}]}",
        "---\nname: review\ndescription: review\n---\nbody\n",
    );
    try std.testing.expectError(error.UnsupportedHostCapability, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.agent_bundle}),
        .packages = &.{.{ .root = root, .layer = .project }},
    }));
    try std.testing.expectError(error.MissingDependency, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.skill_bundle}),
        .packages = &.{.{ .root = root, .layer = .project }},
    }));
}

test "declared but unwired contribution categories fail before snapshot publication" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    try createPackage(
        root,
        "{\"schema_version\":1,\"id\":\"acme.ontology\",\"version\":\"1.0.0\",\"capabilities\":[\"ontology_evidence\"]}",
        null,
    );
    try std.testing.expectError(error.UnsupportedContribution, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        // Even a caller accidentally advertising support cannot publish an
        // empty/fake contribution: Runtime requires a concrete projector.
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.ontology_evidence}),
        .packages = &.{.{ .root = root, .layer = .project }},
    }));

    const provider_plugin = cc.plugin.runtime.StaticPlugin{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.provider"),
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.provider}),
        },
    };
    try std.testing.expectError(error.UnsupportedContribution, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.provider}),
        .static_plugins = &.{provider_plugin},
    }));

    const hook_without_projector = cc.plugin.runtime.StaticPlugin{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.hook"),
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.advisory_hook}),
        },
    };
    try std.testing.expectError(error.UnsupportedContribution, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.advisory_hook}),
        .static_plugins = &.{hook_without_projector},
    }));
}

test "L2 plugin effect lifecycle follows dependency order and atomically rolls back on failure" {
    const allocator = std.testing.allocator;
    var probe = ActivationOrderProbe{};
    var provider_context = ActivationOrderProbe.Context{
        .probe = &probe,
        .activation_event = 1,
        .cleanup_event = 4,
    };
    var consumer_context = ActivationOrderProbe.Context{
        .probe = &probe,
        .activation_event = 2,
        .cleanup_event = 3,
        .fail = true,
    };
    const version = try cc.plugin.contract.Version.parse("1.0.0");
    const provider_id = try cc.plugin.contract.PluginId.parse("acme.provider");
    const requires_provider = [_]cc.plugin.contract.Dependency{.{
        .id = provider_id,
        .minimum = version,
    }};
    const plugins = [_]cc.plugin.runtime.StaticPlugin{
        .{
            .descriptor = .{
                .id = try cc.plugin.contract.PluginId.parse("acme.consumer"),
                .version = version,
                .form = .static_trusted,
                .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
                .dependencies = &requires_provider,
            },
            .tools = &.{ActivationOrderProbe.tool(&consumer_context)},
            .activation = .{ .ctx = &consumer_context, .activate = ActivationOrderProbe.activate },
        },
        .{
            .descriptor = .{
                .id = provider_id,
                .version = version,
                .form = .static_trusted,
                .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
            },
            .tools = &.{ActivationOrderProbe.tool(&provider_context)},
            .activation = .{ .ctx = &provider_context, .activate = ActivationOrderProbe.activate },
        },
    };

    try std.testing.expectError(error.PluginActivationFailed, cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        .static_plugins = &plugins,
    }));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &probe.events);
    try std.testing.expectEqual(@as(usize, 4), probe.count);
}

test "static advisory policies from multiple plugins compose as an intersection" {
    const allocator = std.testing.allocator;
    const deny_write = PolicyFilter{ .denied_name = "Write" };
    const deny_bash = PolicyFilter{ .denied_name = "Bash" };
    const version = try cc.plugin.contract.Version.parse("1.0.0");
    const plugins = [_]cc.plugin.runtime.StaticPlugin{
        .{
            .descriptor = .{
                .id = try cc.plugin.contract.PluginId.parse("acme.no-write"),
                .version = version,
                .form = .static_trusted,
                .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.advisory_hook}),
            },
            .advisory_policy = deny_write.policy(),
        },
        .{
            .descriptor = .{
                .id = try cc.plugin.contract.PluginId.parse("acme.no-bash"),
                .version = version,
                .form = .static_trusted,
                .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.advisory_hook}),
            },
            .advisory_policy = deny_bash.policy(),
        },
    };
    const snapshot = try cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.advisory_hook}),
        .static_plugins = &plugins,
    });
    defer snapshot.destroy();
    const policy = snapshot.executionPolicy() orelse return error.PolicyMissing;
    try std.testing.expect(!policy.allowsTool("Write"));
    try std.testing.expect(!policy.allowsTool("Bash"));
    try std.testing.expect(policy.allowsTool("Read"));
    try std.testing.expect(!policy.allowsInvocation("Write", "{}"));
    try std.testing.expect(!policy.allowsInvocation("Bash", "{}"));
    try std.testing.expect(policy.allowsInvocation("Read", "{}"));
}

test "managed layer deterministically wins before contribution directories are read" {
    const allocator = std.testing.allocator;
    var low_tmp = std.testing.tmpDir(.{});
    defer low_tmp.cleanup();
    var high_tmp = std.testing.tmpDir(.{});
    defer high_tmp.cleanup();
    var low_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var high_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const low = try realRoot(&low_tmp, &low_buffer);
    const high = try realRoot(&high_tmp, &high_buffer);
    const low_manifest = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"skill_bundle\"]}";
    const high_manifest = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"2.0.0\",\"capabilities\":[\"skill_bundle\"]}";
    try createPackage(low, low_manifest, null);
    try createPackage(high, high_manifest, "---\nname: review\ndescription: managed\n---\nmanaged\n");
    const snapshot = try cc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(2),
        .supported_capabilities = cc.plugin.contract.CapabilitySet.from(&.{.skill_bundle}),
        .packages = &.{
            .{ .root = high, .layer = .managed },
            .{ .root = low, .layer = .personal },
        },
    });
    defer snapshot.destroy();
    try std.testing.expectEqual(@as(usize, 1), snapshot.plugins.len);
    try std.testing.expectEqual(@as(u32, 2), snapshot.plugins[0].descriptor.version.major);
    try std.testing.expect(std.mem.startsWith(u8, snapshot.skill_sources[0].root, high));
}
