//! L2 coverage for fork execution through the canonical shared Skill Runtime.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"forked-reply\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const READ_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn makeSkill(root: []const u8, name: []const u8, definition: []const u8) !void {
    const allocator = std.testing.allocator;
    const root_z = try allocator.dupeZ(u8, root);
    defer allocator.free(root_z);
    _ = std.c.mkdir(root_z, 0o755);
    const skill_dir = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ root, name },
        0,
    );
    defer allocator.free(skill_dir);
    _ = std.c.mkdir(skill_dir, 0o755);
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/SKILL.md",
        .{ root, name },
        0,
    );
    defer allocator.free(path);
    const fd = pfs.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    _ = pfs.write(fd, definition);
    pfs.close(fd);
}

fn cleanup(root: []const u8, name: []const u8) void {
    const allocator = std.testing.allocator;
    const path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/SKILL.md",
        .{ root, name },
        0,
    ) catch return;
    defer allocator.free(path);
    _ = std.c.unlink(path);
    const skill_dir = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ root, name },
        0,
    ) catch return;
    defer allocator.free(skill_dir);
    _ = std.c.rmdir(skill_dir);
    const root_z = allocator.dupeZ(u8, root) catch return;
    defer allocator.free(root_z);
    _ = std.c.rmdir(root_z);
}

const Host = struct {
    fn activate(
        _: *anyopaque,
        _: []const u8,
        _: []const []const u8,
        _: []const []const u8,
    ) anyerror!void {}
};

const Fixture = struct {
    runtime: cc.skills_cli_adapter.Runtime,
    projection: cc.skills.SkillSet,
    registry: cc.tools_dynamic.DynRegistry,
    abort: cc.util_abort.AbortSignal,
    permission: cc.permission.PermissionContext,
    tool_defs: []cc.json_mod.ToolDefinition,
    host_token: u8 = 0,

    fn init(
        self: *Fixture,
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
    ) !void {
        self.* = .{
            .runtime = cc.skills_cli_adapter.Runtime.init(allocator, io),
            .projection = cc.skills.SkillSet.init(allocator),
            .registry = cc.tools_dynamic.DynRegistry.init(allocator),
            .abort = cc.util_abort.AbortSignal.init(),
            .permission = .{
                .mode = .init(.bypass_permissions),
                .allocator = allocator,
            },
            .tool_defs = try cc.tools.toToolDefinitions(allocator),
        };
        errdefer allocator.free(self.tool_defs);
        errdefer self.registry.deinit();
        errdefer self.projection.deinit();
        errdefer self.runtime.deinit();

        const sources = [_]cc.skills_runtime.catalog.Source{.{
            .root = root,
            .scope = .project,
            .priority = 300,
        }};
        try self.runtime.loadSources(root, "", "", &sources, &self.projection);
        try cc.skills_tool.registerSkillTool(&self.registry, &self.runtime);
        const model_defs = try cc.tools.toToolDefinitionsWithDyn(
            allocator,
            &self.registry,
        );
        allocator.free(self.tool_defs);
        self.tool_defs = model_defs;
        if (!cc.skills_cli_adapter.applyModelToolSchema(self.tool_defs))
            return error.SkillSchemaMissing;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.registry.deinit();
        self.runtime.deinit();
        self.projection.deinit();
        allocator.free(self.tool_defs);
        self.* = undefined;
    }

    fn context(
        self: *Fixture,
        allocator: std.mem.Allocator,
        root: []const u8,
        client: ?*cc.client_mod.Client,
    ) cc.tools.ToolContext {
        var ctx = cc.tools.ToolContext.withAbort(allocator, &self.abort);
        ctx.api_client = client;
        ctx.tool_defs = self.tool_defs;
        ctx.permission_ctx = &self.permission;
        ctx.dyn_registry = &self.registry;
        ctx.project_dir = root;
        ctx.cwd_abs = root;
        ctx.host_services = .{
            .ctx = @ptrCast(&self.host_token),
            .activateSkillFn = &Host.activate,
        };
        return ctx;
    }
};

test "L2: shared Runtime fork sends rendered body to child" {
    const allocator = std.testing.allocator;
    const root = "/tmp/metacodes-skill-fork-body";
    defer cleanup(root, "forky");
    try makeSkill(
        root,
        "forky",
        "---\nname: forky\ndescription: forks\ncontext: fork\n---\nFORK_BODY_MARKER do the thing\n",
    );

    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, &client);
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(
        &ctx,
        "{\"name\":\"forky\"}",
    );
    defer output_body.deinit(allocator);
    const output = output_body.@"inline".bytes;

    try std.testing.expect(std.mem.indexOf(u8, output, "(forked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "forked-reply") != null);
    const capture = server.lastRequest() orelse return error.NoRequestCaptured;
    const messages = capture.jsonField("messages") orelse
        return error.MessagesFieldMissing;
    try std.testing.expect(
        std.mem.indexOf(u8, messages, "FORK_BODY_MARKER") != null,
    );
    try std.testing.expect(fixture.runtime.currentPolicyFrame() == null);
    try std.testing.expect(fixture.permission.active_skill == null);
}

test "L2: shared Runtime inline does not spawn child" {
    const allocator = std.testing.allocator;
    const root = "/tmp/metacodes-skill-inline";
    defer cleanup(root, "inliney");
    try makeSkill(
        root,
        "inliney",
        "---\nname: inliney\ndescription: inline\n---\nINLINE_BODY just text\n",
    );

    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, &client);
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(
        &ctx,
        "{\"name\":\"inliney\"}",
    );
    defer output_body.deinit(allocator);
    const output = output_body.@"inline".bytes;

    try std.testing.expect(std.mem.indexOf(u8, output, "INLINE_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(forked)") == null);
    try std.testing.expect(server.lastRequest() == null);
}

test "L2: shared Runtime fork honors model override" {
    const allocator = std.testing.allocator;
    const root = "/tmp/metacodes-skill-fork-model";
    defer cleanup(root, "haikufork");
    try makeSkill(
        root,
        "haikufork",
        "---\nname: haikufork\ndescription: fork haiku\ncontext: fork\nmodel: haiku\n---\nbody here\n",
    );

    var server = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(allocator, io_runtime.io(), root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, &client);
    const entry = fixture.registry.find("Skill").?;
    var output_body = try entry.execute(
        &ctx,
        "{\"name\":\"haikufork\"}",
    );
    defer output_body.deinit(allocator);
    try std.testing.expect(output_body == .@"inline");
    const capture = server.lastRequest() orelse return error.NoRequestCaptured;
    const model = capture.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model, "haiku") != null);
}

test "L2: unsupported agent binding fails before child execution" {
    const allocator = std.testing.allocator;
    const root = "/tmp/metacodes-skill-agent-unavailable";
    defer cleanup(root, "agentfork");
    try makeSkill(
        root,
        "agentfork",
        "---\nname: agentfork\ndescription: unavailable binding\ncontext: fork\nagent: custom\n---\nbody\n",
    );
    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, null);
    const entry = fixture.registry.find("Skill").?;
    try std.testing.expectError(
        error.SkillUnavailable,
        entry.execute(&ctx, "{\"name\":\"agentfork\"}"),
    );
}

test "L2: fork without child runner fails closed and never falls back inline" {
    const allocator = std.testing.allocator;
    const root = "/tmp/metacodes-skill-fork-unavailable";
    defer cleanup(root, "nofork");
    try makeSkill(
        root,
        "nofork",
        "---\nname: nofork\ndescription: requires fork\ncontext: fork\n---\nNO_FALLBACK_BODY\n",
    );
    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root, null);
    const entry = fixture.registry.find("Skill").?;
    try std.testing.expectError(
        error.ForkUnavailable,
        entry.execute(&ctx, "{\"name\":\"nofork\"}"),
    );
    try std.testing.expect(fixture.runtime.currentPolicyFrame() == null);
}

const ProjectionProbe = struct {
    text: usize = 0,
    stream_done: usize = 0,
    tool_start: usize = 0,
    tool_result: usize = 0,
    usage: usize = 0,

    fn backend(self: *ProjectionProbe) cc.ui_backend.UiBackend {
        return .{ .ctx = self, .emit = emit, .poll = poll };
    }

    fn emit(
        raw: *anyopaque,
        _: cc.session_id.SessionId,
        event: cc.ui_event.CoreEvent,
    ) void {
        const self: *ProjectionProbe = @ptrCast(@alignCast(raw));
        switch (event) {
            .text_chunk => self.text += 1,
            .stream_done => self.stream_done += 1,
            .tool_start => self.tool_start += 1,
            .tool_result => self.tool_result += 1,
            .usage => self.usage += 1,
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

test "L2: AgentCore fork capture preserves raw boundaries at true child depth" {
    const allocator = std.testing.allocator;
    const bodies = [_][]const u8{
        READ_TOOL_SSE,
        MINIMAL_END_TURN_SSE,
        READ_TOOL_SSE,
        MINIMAL_END_TURN_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "test-model",
        url,
    );
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tool_defs = try cc.tools.toToolDefinitions(arena.allocator());
    var permission = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = allocator,
    };

    var root_probe = ProjectionProbe{};
    const root_backend = root_probe.backend();
    const root_result = try cc.core_subagent.spawnAgentSink(
        allocator,
        client.provider(),
        &client,
        tool_defs,
        &permission,
        null,
        "exercise run-root projection",
        .{
            .max_turns = 3,
            .agent_depth = 2,
            .event_projection = .run_root,
        },
        &root_backend,
    );
    defer root_result.deinit();
    try std.testing.expectEqual(
        cc.agent_loop.StopReason.end_turn,
        root_result.stop_reason,
    );
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_start);
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_result);
    try std.testing.expect(root_probe.text > 0);
    try std.testing.expectEqual(@as(usize, 2), root_probe.stream_done);
    try std.testing.expect(root_probe.usage > 0);

    var model_probe = ProjectionProbe{};
    const model_backend = model_probe.backend();
    const model_result = try cc.core_subagent.spawnAgentSink(
        allocator,
        client.provider(),
        &client,
        tool_defs,
        &permission,
        null,
        "exercise model-tool projection",
        .{
            .max_turns = 3,
            .agent_depth = 2,
            .event_projection = .model_tool,
        },
        &model_backend,
    );
    defer model_result.deinit();
    try std.testing.expectEqual(
        cc.agent_loop.StopReason.end_turn,
        model_result.stop_reason,
    );
    try std.testing.expectEqual(@as(usize, 1), model_probe.tool_start);
    try std.testing.expectEqual(@as(usize, 1), model_probe.tool_result);
    try std.testing.expect(model_probe.text > 0);
    try std.testing.expectEqual(@as(usize, 2), model_probe.stream_done);
    try std.testing.expect(model_probe.usage > 0);
}
