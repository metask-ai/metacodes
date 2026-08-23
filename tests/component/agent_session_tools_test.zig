//! AgentCore library vertical slice: Runtime catalog -> Session selection ->
//! provider advertisement -> admission -> built-in execution -> next request.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

var dialect_test_ctx: u8 = 0;

fn injectPluginDialectMarker(
    _: *anyopaque,
    _: cc.model_adapter.ModelProfile,
    _: ?cc.api_dialect.ReasoningEffort,
    system: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) anyerror!void {
    try system.appendSlice(allocator, "\nPLUGIN_DIALECT_MARKER");
}

const plugin_test_dialect = cc.api_dialect.Dialect{
    .ctx = @ptrCast(&dialect_test_ctx),
    .injectSystemModsFn = injectPluginDialectMarker,
};

var skill_surface_ctx: u8 = 0;

fn rejectSkillDispatch(
    _: *const anyopaque,
    _: *const cc.tool_context.ToolContext,
    _: []const u8,
    _: []const u8,
) anyerror!cc.tools.ToolDispatchOutcome {
    return error.UnexpectedToolDispatch;
}

fn skillSurfacePrefetchSafe(_: *const anyopaque, _: []const u8) bool {
    return false;
}

fn skillSurfaceNameAt(_: *const anyopaque, index: usize) ?[]const u8 {
    return if (index == 0) "Skill" else null;
}

fn skillSurfaceHostSync(_: *const anyopaque, _: []const u8) bool {
    return false;
}

fn skillSurfaceDispatcher() cc.tools.ToolDispatcher {
    return .{
        .ctx = @ptrCast(&skill_surface_ctx),
        .dispatchFn = rejectSkillDispatch,
        .prefetchSafeFn = skillSurfacePrefetchSafe,
        .nameAtFn = skillSurfaceNameAt,
        .hostSyncFn = skillSurfaceHostSync,
    };
}

const GLOB_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_glob\",\"name\":\"Glob\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"*.workspace-probe\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const WEB_SEARCH_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_web\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_search\",\"name\":\"WebSearch\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"zig language\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ISOLATED_WEB_SEARCH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_nested\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srv_1\",\"name\":\"web_search\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srv_1\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Zig Lang\",\"url\":\"https://ziglang.org\"}]}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Zig is a systems language.\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn readToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn bashToolSse(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_bash\",\"name\":\"Bash\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"command\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{command});
}

fn writeToolSse(allocator: std.mem.Allocator, path: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_write\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_write\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{ path, content });
}

fn writeFile(path: [*:0]const u8, content: []const u8) !void {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = pfs.write(fd, content[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

test "L2 artifact-enabled Host-only Session advertises its mandatory recovery plugin from request one" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var enabled_server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer enabled_server.stop();
    var disabled_server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer disabled_server.stop();
    const enabled_url = try enabled_server.urlOwned(allocator);
    defer allocator.free(enabled_url);
    const disabled_url = try disabled_server.urlOwned(allocator);
    defer allocator.free(disabled_url);

    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const inventory = try runtime.describePlugins(allocator);
    defer allocator.free(inventory);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "metacodes.kernel.tool-result-artifact") != null);

    const enabled = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = enabled_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .home = root, .shell = .disabled },
        .artifact_store = .{ .exact_root = root },
        .allowed_tools = &.{},
    });
    defer enabled.destroy() catch unreachable;
    const disabled = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = disabled_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .home = root, .shell = .disabled },
        .allowed_tools = &.{},
    });
    defer disabled.destroy() catch unreachable;
    try std.testing.expect(enabled.tools.contains("ReadArtifact"));
    try std.testing.expect(!disabled.tools.contains("ReadArtifact"));

    var sink_state: u8 = 0;
    _ = try enabled.runText(1, "enabled", 1, .{ .ctx = &sink_state, .emit = Sink.emit });
    _ = try disabled.runText(1, "disabled", 1, .{ .ctx = &sink_state, .emit = Sink.emit });
    const enabled_body = (enabled_server.lastRequest() orelse return error.NoRequestCaptured).body();
    const disabled_body = (disabled_server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, enabled_body, "\"name\":\"ReadArtifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, disabled_body, "\"name\":\"ReadArtifact\"") == null);
}

test "L2 AgentSession resolves selected built-in file tools against its workspace" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    // 归一正斜杠:file_path 会拼进 SSE JSON 字符串,Windows 反斜杠是非法 JSON 转义。
    for (root_buf[0..root_len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    const root = root_buf[0..root_len];
    const file_path = try std.fmt.allocPrintSentinel(a, "{s}/sample.txt", .{root}, 0);
    defer a.free(file_path);
    try writeFile(file_path.ptr, "agentcore-tool-ok\n");
    const glob_probe_name = "agentcore-workspace-only-7f6e8ad1.workspace-probe";
    const glob_probe_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, glob_probe_name }, 0);
    defer a.free(glob_probe_path);
    try writeFile(glob_probe_path.ptr, "glob-workspace-ok\n");

    // The provider intentionally emits a relative path while the test process
    // runs outside `root`. AgentSession must bind it to the Host workspace.
    const tool_sse = try readToolSse(a, "sample.txt");
    defer a.free(tool_sse);
    const bodies = [_][]const u8{ tool_sse, GLOB_TOOL_SSE, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const Runtime = cc.agent_session.AgentRuntime;
    const runtime = try Runtime.create(a, .{ .builtin_tools = &.{ "Read", "Glob", "Bash" } });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{ "Read", "Glob" },
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "read the file", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);

    const request = srv.lastRequest() orelse return error.NoRequestCaptured;
    const body = request.body();
    // The final request carries both the relative Read result and the Glob
    // result produced with its omitted path defaulting to workspace-root ".".
    // Runtime's Bash entry never crosses the Session ceiling.
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"name\\\":\\\"Read\\\"") != null or std.mem.indexOf(u8, body, "\"name\":\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"name\\\":\\\"Glob\\\"") != null or std.mem.indexOf(u8, body, "\"name\":\"Glob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "agentcore-tool-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, glob_probe_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"name\\\":\\\"Bash\\\"") == null and std.mem.indexOf(u8, body, "\"name\":\"Bash\"") == null);
}

test "L2 RuntimeHost hot-swaps first-party core profiles without mutating live Sessions" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    for (root_buf[0..root_len]) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    const root = root_buf[0..root_len];
    const source_path = try std.fmt.allocPrintSentinel(a, "{s}/source.txt", .{root}, 0);
    defer a.free(source_path);
    const target_path = try std.fmt.allocPrintSentinel(a, "{s}/hot-swapped.txt", .{root}, 0);
    defer a.free(target_path);
    try writeFile(source_path.ptr, "generation-one-readable\n");

    const read_sse = try readToolSse(a, "source.txt");
    defer a.free(read_sse);
    const write_sse = try writeToolSse(a, target_path, "generation-two-writable");
    defer a.free(write_sse);
    const old_bodies = [_][]const u8{ read_sse, FINAL_SSE };
    const new_bodies = [_][]const u8{ write_sse, FINAL_SSE };
    var old_server = try harness.MockServer.startCassette(&old_bodies, 0);
    defer old_server.stop();
    var new_server = try harness.MockServer.startCassette(&new_bodies, 0);
    defer new_server.stop();
    const old_url = try old_server.urlOwned(a);
    defer a.free(old_url);
    const new_url = try new_server.urlOwned(a);
    defer a.free(new_url);

    const host = try cc.agent_session.RuntimeHost.create(a, .{ .core_profile = .minimal });
    defer host.destroy() catch unreachable;
    const initial_inventory = try host.describePlugins(a);
    defer a.free(initial_inventory);
    try std.testing.expect(std.mem.indexOf(u8, initial_inventory, "metacodes.core.minimal") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial_inventory, "builtin_tool_bundle") != null);

    const old_session = try host.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = old_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{"Read"},
    });
    defer old_session.destroy() catch unreachable;

    const generation = try host.replace(.{ .core_profile = .coding });
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(generation));
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(old_session.pluginGeneration()));
    try std.testing.expect(!old_session.tools.contains("Write"));
    const current_inventory = try host.describePlugins(a);
    defer a.free(current_inventory);
    try std.testing.expect(std.mem.indexOf(u8, current_inventory, "metacodes.core.coding") != null);
    try std.testing.expect(std.mem.indexOf(u8, current_inventory, "metacodes.core.minimal") == null);

    const new_session = try host.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = new_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{"Write"},
    });
    defer new_session.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(new_session.pluginGeneration()));
    try std.testing.expect(new_session.tools.contains("Write"));

    var sink_state: u8 = 0;
    const old_result = try old_session.runText(1, "read through generation one", 3, .{ .ctx = &sink_state, .emit = Sink.emit });
    const new_result = try new_session.runText(1, "write through generation two", 3, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, old_result.stop_reason);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, new_result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), old_result.tool_calls);
    try std.testing.expectEqual(@as(u32, 1), new_result.tool_calls);
    const old_body = (old_server.lastRequest() orelse return error.NoRequestCaptured).body();
    const new_body = (new_server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.c.access(target_path.ptr, std.c.F_OK) == 0);
    try std.testing.expect(std.mem.indexOf(u8, old_body, "generation-one-readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, old_body, "\"name\":\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, old_body, "\\\"name\\\":\\\"Write\\\"") == null and std.mem.indexOf(u8, old_body, "\"name\":\"Write\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, old_body, "To read files use Read") != null);
    try std.testing.expect(std.mem.indexOf(u8, old_body, "To create files use Write") == null);
    try std.testing.expect(std.mem.indexOf(u8, new_body, "\"name\":\"Write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_body, "\"name\":\"Read\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, new_body, "To create files use Write") != null);
    try std.testing.expect(std.mem.indexOf(u8, new_body, "To read files use Read") == null);
    try std.testing.expect(std.mem.indexOf(u8, new_body, "generation-two-writable") != null);
}

test "L2 provider dialect plugin is generation-pinned and equivalent replacement preserves request cache bytes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    var baseline_server = try harness.MockServer.startCassette(&.{OPENAI_FINAL_SSE}, 0);
    defer baseline_server.stop();
    var plugin_server = try harness.MockServer.startCassette(&.{OPENAI_FINAL_SSE}, 0);
    defer plugin_server.stop();
    var equivalent_server = try harness.MockServer.startCassette(&.{OPENAI_FINAL_SSE}, 0);
    defer equivalent_server.stop();
    const baseline_url = try baseline_server.urlOwned(a);
    defer a.free(baseline_url);
    const plugin_url = try plugin_server.urlOwned(a);
    defer a.free(plugin_url);
    const equivalent_url = try equivalent_server.urlOwned(a);
    defer a.free(equivalent_url);

    const dialect_plugin = cc.plugin.runtime.StaticPlugin{
        .descriptor = .{
            .id = try cc.plugin.contract.PluginId.parse("acme.model-dialect"),
            .version = try cc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = cc.plugin.contract.CapabilitySet.from(&.{.provider_dialect}),
        },
        .provider_dialects = &.{.{
            .provider_kind = .openai,
            .model_prefix = "acme-model-",
            .dialect = plugin_test_dialect,
        }},
    };

    const host = try cc.agent_session.RuntimeHost.create(a, .{ .core_profile = .none });
    defer host.destroy() catch unreachable;
    const baseline_session = try host.createSession(.{
        .provider_kind = .openai,
        .api_key = "test-key",
        .model = "acme-model-1",
        .base_url = baseline_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{},
    });
    defer baseline_session.destroy() catch unreachable;

    _ = try host.replace(.{ .core_profile = .none, .static_plugins = &.{dialect_plugin} });
    const plugin_session = try host.createSession(.{
        .provider_kind = .openai,
        .api_key = "test-key",
        .model = "acme-model-1",
        .base_url = plugin_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{},
    });
    defer plugin_session.destroy() catch unreachable;

    // Publishing an equivalent generation must not inject generation/plugin
    // inventory into provider-visible bytes and therefore must not break the
    // prefix cache.
    _ = try host.replace(.{ .core_profile = .none, .static_plugins = &.{dialect_plugin} });
    const equivalent_session = try host.createSession(.{
        .provider_kind = .openai,
        .api_key = "test-key",
        .model = "acme-model-1",
        .base_url = equivalent_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{},
    });
    defer equivalent_session.destroy() catch unreachable;
    const inventory = try host.describePlugins(a);
    defer a.free(inventory);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "provider_dialect") != null);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "acme.model-dialect") != null);

    var sink_state: u8 = 0;
    _ = try baseline_session.runText(1, "identical prompt", 1, .{ .ctx = &sink_state, .emit = Sink.emit });
    _ = try plugin_session.runText(1, "identical prompt", 1, .{ .ctx = &sink_state, .emit = Sink.emit });
    _ = try equivalent_session.runText(1, "identical prompt", 1, .{ .ctx = &sink_state, .emit = Sink.emit });

    const baseline_body = (baseline_server.lastRequest() orelse return error.NoRequestCaptured).body();
    const plugin_body = (plugin_server.lastRequest() orelse return error.NoRequestCaptured).body();
    const equivalent_body = (equivalent_server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, baseline_body, "PLUGIN_DIALECT_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, plugin_body, "PLUGIN_DIALECT_MARKER") != null);
    try std.testing.expectEqualStrings(plugin_body, equivalent_body);
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(baseline_session.pluginGeneration()));
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(plugin_session.pluginGeneration()));
    try std.testing.expectEqual(@as(u64, 3), @intFromEnum(equivalent_session.pluginGeneration()));
}

test "L2 Anthropic GLM sees typed Skill capability activation in the real AgentSession request" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{ .core_profile = .none });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "glm-5.2",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{},
    });
    defer session.destroy() catch unreachable;

    const skill = cc.json_mod.ToolDefinition{
        .name = "Skill",
        .description = "Invoke the exact bound skill before other work when it clearly matches.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "skill", .type = "string" },
        }, .required = &.{"skill"} },
    };
    var sink_state: u8 = 0;
    var admitted = try session.admitRun(1, .{ .ctx = &sink_state, .emit = Sink.emit });
    const result = try admitted.runUserMessagesWithToolSurface(
        &.{"review this change"},
        1,
        null,
        .{ .definitions = &.{skill}, .dispatcher = skillSurfaceDispatcher() },
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"Skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Model-specific capability activation") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "blocking requirement") != null);
    // An ordinary advisory Skill gets model-specific guidance but never an
    // unconditional forced route. Only explicit required-first metadata can
    // request that stronger behavior.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
}

test "L2 AgentSession exposes WebSearch as a builtin and dispatches its isolated provider search" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    const bodies = [_][]const u8{ WEB_SEARCH_TOOL_SSE, ISOLATED_WEB_SEARCH_SSE, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{
        .builtin_tools = &.{"WebSearch"},
    });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{"WebSearch"},
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "search and fetch", 3, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);

    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "WebSearch") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Web search results for query") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zig language") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "https://ziglang.org") != null);
}

test "L2 AgentSession rejects an unadvertised Runtime tool before prefetch or dispatch" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/must-not-exist", .{root}, 0);
    defer a.free(marker);
    const command = try std.fmt.allocPrint(a, "touch {s}", .{marker});
    defer a.free(command);
    const tool_sse = try bashToolSse(a, command);
    defer a.free(tool_sse);

    const bodies = [_][]const u8{ tool_sse, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{ "Read", "Bash" } });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{"Read"},
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "do not trust the provider", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expect(std.c.access(marker.ptr, std.c.F_OK) != 0);
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "unknown_tool") != null);
}

test "L2 AgentSession Bash 子进程 cwd 绑 workspace.root(缺陷 B 回归)" {
    // 缺陷 B:子进程必须 chdir 到 workspace.root,而非继承父进程(测试进程)cwd。
    // 验证:workspace.root 设为 tmp 目录(≠ 测试进程 cwd),Bash 跑 `pwd`,
    // tool_result 在下一请求 body 里出现,且含 workspace.root 路径片段。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    // JSON 会转义 Windows 路径中的反斜杠；basename 在两平台都无需路径
    // 归一化，并且 std.testing.tmpDir 生成的名字足够区分父进程 cwd。
    const root_basename = std.fs.path.basename(root);

    const tool_sse = try bashToolSse(a, "pwd");
    defer a.free(tool_sse);
    const bodies = [_][]const u8{ tool_sse, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const Runtime = cc.agent_session.AgentRuntime;
    const runtime = try Runtime.create(a, .{ .builtin_tools = &.{ "Read", "Bash" } });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .unrestricted },
        .allowed_tools = &.{ "Read", "Bash" },
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "print working dir", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);

    // 下一请求 body 应含 tool_result,其 stdout 含 workspace.root(子进程在 root 下跑 pwd)。
    // 用 count >= 2 区分:system_prompt 的 environment 段含 basename 一次(永远存在),
    // tool_result 的 pwd 输出含 basename 一次(仅当子进程真 chdir 到 root)。若 chdir 没接线,
    // tool_result 的 pwd 是测试进程 cwd(≠ root),count 仅 1 → 测试 FAIL。Linus R21。
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.count(u8, body, root_basename) >= 2);
}
