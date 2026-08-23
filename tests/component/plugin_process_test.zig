//! L2 process-plugin proof: strict package -> immutable Runtime snapshot ->
//! provider advertisement -> native permission -> one-shot child -> tool result.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const psync = @import("platform").sync;
const ppaths = @import("platform").paths;

const TOOL_NAME = "acme_dreview__Echo";

const TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_process\",\"name\":\"" ++ TOOL_NAME ++ "\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const CallMode = enum { ok, artifact_spool, timeout, crash, invalid_frame, output_flood, env_probe, bad_handshake };

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

const HANDSHAKE_BODY =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"handshake\",\"protocol_major\":1," ++
    "\"plugin_id\":\"acme.review\",\"plugin_version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]," ++
    "\"limits\":{\"max_request_frame_bytes\":2048,\"max_response_bytes\":65536},\"cancellation\":\"terminate_process_group\"," ++
    "\"tools\":[{\"name\":\"Echo\",\"description\":\"Echo through a pinned process plugin\"," ++
    "\"input_schema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}";

const BAD_HANDSHAKE_BODY =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"handshake\",\"protocol_major\":1," ++
    "\"plugin_id\":\"evil.swap\",\"plugin_version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]," ++
    "\"limits\":{\"max_request_frame_bytes\":2048,\"max_response_bytes\":65536},\"cancellation\":\"terminate_process_group\"," ++
    "\"tools\":[{\"name\":\"Echo\",\"description\":\"bad\",\"input_schema\":{\"type\":\"object\"}}]}";

const ARTIFACT_HANDSHAKE_BODY =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"handshake\",\"protocol_major\":1," ++
    "\"plugin_id\":\"acme.review\",\"plugin_version\":\"1.0.0\",\"capabilities\":[\"host_tool\",\"artifact_spool_v1\"]," ++
    "\"limits\":{\"max_request_frame_bytes\":2048,\"max_response_bytes\":65536},\"cancellation\":\"terminate_process_group\"," ++
    "\"tools\":[{\"name\":\"Echo\",\"description\":\"Spool through a pinned process plugin\"," ++
    "\"input_schema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}";

const CALL_BODY =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"call_result\",\"protocol_major\":1," ++
    "\"plugin_id\":\"acme.review\",\"plugin_version\":\"1.0.0\",\"tool\":\"Echo\"," ++
    "\"status\":\"ok\",\"content\":\"process-plugin-ok\"}";

const ARTIFACT_CALL_BODY =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"call_result\",\"protocol_major\":1," ++
    "\"plugin_id\":\"acme.review\",\"plugin_version\":\"1.0.0\",\"tool\":\"Echo\"," ++
    "\"status\":\"artifact\",\"media_type\":\"text/plain; charset=utf-8\"}";

fn realRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

fn createPackage(root: []const u8, mode: CallMode, call_timeout_ms: u64) ![]u8 {
    const allocator = std.testing.allocator;
    const meta = try std.fmt.allocPrint(allocator, "{s}/.metacodes-plugin", .{root});
    defer allocator.free(meta);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, meta);

    const script = switch (mode) {
        .ok => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\else
            \\  : > call.marker
            \\  body='{s}'
            \\fi
            \\printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\
        , .{ HANDSHAKE_BODY, CALL_BODY }),
        .artifact_spool => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\else
            \\  request=$(cat)
            \\  spool=$(printf '%s' "$request" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')
            \\  [ -n "$spool" ] || exit 24
            \\  printf 'PLUGIN_HEAD-' > "$spool"
            \\  awk 'BEGIN {{ for (i=0;i<81920;i++) printf "x" }}' >> "$spool"
            \\  printf '%s' '-PLUGIN_TAIL' >> "$spool"
            \\  body='{s}'
            \\fi
            \\printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\
        , .{ ARTIFACT_HANDSHAKE_BODY, ARTIFACT_CALL_BODY }),
        .timeout => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\  printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\else
            \\  echo $$ > child.pid
            \\  /bin/sleep 5
            \\fi
            \\
        , .{HANDSHAKE_BODY}),
        .crash => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\  printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\else
            \\  exit 17
            \\fi
            \\
        , .{HANDSHAKE_BODY}),
        .invalid_frame => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\  printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\else
            \\  printf 'not-a-frame'
            \\fi
            \\
        , .{HANDSHAKE_BODY}),
        .output_flood => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\  printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\else
            \\  while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done
            \\fi
            \\
        , .{HANDSHAKE_BODY}),
        .env_probe => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\if [ -n "${{METACODES_PLUGIN_SECRET+x}}" ]; then exit 23; fi
            \\if [ "$1" = "handshake" ]; then
            \\  body='{s}'
            \\else
            \\  body='{s}'
            \\fi
            \\printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\
        , .{ HANDSHAKE_BODY, CALL_BODY }),
        .bad_handshake => try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\body='{s}'
            \\printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
            \\
        , .{BAD_HANDSHAKE_BODY}),
    };

    const entrypoint = try std.fmt.allocPrint(allocator, "{s}/plugin.sh", .{root});
    errdefer allocator.free(entrypoint);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = entrypoint, .data = script });
    allocator.free(script);
    const entrypoint_z = try allocator.dupeZ(u8, entrypoint);
    defer allocator.free(entrypoint_z);
    if (std.c.chmod(entrypoint_z.ptr, 0o700) != 0) return error.SkipZigTest;

    var digest: [32]u8 = undefined;
    const script_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, entrypoint, allocator, .limited(1024 * 1024));
    defer allocator.free(script_bytes);
    std.crypto.hash.sha2.Sha256.hash(script_bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/plugin.json", .{meta});
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]}",
    });
    const process_path = try std.fmt.allocPrint(allocator, "{s}/process.json", .{meta});
    defer allocator.free(process_path);
    const process_config = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"protocol_major\":1,\"entrypoint\":\"plugin.sh\",\"sha256\":\"{s}\",\"handshake_timeout_ms\":10000,\"call_timeout_ms\":{d},\"max_response_bytes\":65536}}",
        .{ hash, call_timeout_ms },
    );
    defer allocator.free(process_config);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = process_path, .data = process_config });
    return entrypoint;
}

fn createRuntime(root: []const u8) !*cc.agent_session.AgentRuntime {
    const packages = [_]cc.agent_session.ProcessPlugin{.{ .root = root, .layer = .session }};
    return cc.agent_session.AgentRuntime.create(std.testing.allocator, .{
        .builtin_tools = &.{},
        .process_plugins = &packages,
    });
}

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

test "L2 repeatable --process-plugin-dir is an explicit executable authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][*:0]const u8{
        "metacodes",
        "--process-plugin-dir",
        "plugins/one",
        "--process-plugin-dir",
        "plugins/two",
        "--dump-plugins",
    };
    const config = cc.parseArgsForTest(&argv, arena.allocator());
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqualStrings("plugins/one\x00plugins/two", config.process_plugin_dirs.?);
    try std.testing.expect(config.plugin_dirs == null);

    const missing = [_][*:0]const u8{ "metacodes", "--process-plugin-dir" };
    const invalid = cc.parseArgsForTest(&missing, arena.allocator());
    try std.testing.expect(invalid.parse_error != null);
}

test "L2 CLI process package preserves typed artifact through DynRegistry and AgentLoop" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .artifact_spool, 1000);
    defer std.testing.allocator.free(entrypoint);

    const bodies = [_][]const u8{ TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const url = try server.urlOwned(allocator);
    const root_z = try allocator.dupeZ(u8, root);
    const url_z = try allocator.dupeZ(u8, url);
    const argv = [_][*:0]const u8{
        "metacodes",
        "--process-plugin-dir",
        root_z.ptr,
        "--base-url",
        url_z.ptr,
        "--model",
        "test-model",
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
    const dynamic = app.dyn_registry.find(TOOL_NAME) orelse return error.ProcessToolMissing;
    try std.testing.expectEqual(cc.permission.ToolCategory.execute, dynamic.category.?);
    try std.testing.expect(dynamic.executor == .result_body);
    try std.testing.expect(dynamic.borrowed_input_schema.?.properties.?.get("text") != null);
    var plan_permission = cc.permission.createContext(.plan, allocator);
    try std.testing.expectEqual(
        cc.permission.PermissionResult.deny,
        cc.permission.checkPermissionClassified(
            &plan_permission,
            TOOL_NAME,
            "{\"text\":\"hello\"}",
            app.dyn_registry.category(TOOL_NAME),
        ),
    );

    try app.conversation.appendText(.user, "call the configured process plugin");
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        .{
            .max_turns = 4,
            .system_prompt = app.system_prompt,
            .dyn_registry = &app.dyn_registry,
            .cwd_abs = root,
            .artifact_root = root,
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, TOOL_NAME) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ReadArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "PLUGIN_HEAD-") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "-PLUGIN_TAIL") != null);
}

test "L2 process plugin is namespaced advertised permissioned executed and projected" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .ok, 1000);
    defer allocator.free(entrypoint);

    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    const record = runtime.plugin_snapshot.find("acme.review") orelse return error.PluginMissing;
    try std.testing.expectEqual(cc.plugin.contract.Form.out_of_process, record.descriptor.form);
    try std.testing.expectEqual(@as(usize, 1), record.contribution_count);
    const entry = runtime.catalog.find(TOOL_NAME) orelse return error.ProcessToolMissing;
    try std.testing.expect(entry.executor == .isolated);
    try std.testing.expectEqual(cc.permission.ToolCategory.execute, entry.category);

    const bodies = [_][]const u8{ TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{TOOL_NAME},
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "call the process plugin", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, TOOL_NAME) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "process-plugin-ok") != null);
    const marker = try std.fmt.allocPrint(allocator, "{s}/call.marker", .{root});
    defer allocator.free(marker);
    try std.Io.Dir.cwd().access(std.testing.io, marker, .{});
}

test "L2 process plugin writes from byte zero into the kernel artifact spool" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .artifact_spool, 1000);
    defer allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    var selection = try cc.tool_catalog.Selection.init(allocator, &runtime.catalog, &.{TOOL_NAME});
    defer selection.deinit();
    var tool_ctx = cc.tool_context.ToolContext.simple(allocator);
    tool_ctx.tool_dispatcher = selection.dispatcher();
    tool_ctx.artifact_root = root;
    var outcome = try selection.dispatcher().dispatch(&tool_ctx, TOOL_NAME, "{\"text\":\"hello\"}");
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expect(outcome.ok == .artifact);
    try std.testing.expect(outcome.ok.artifact.stored.bytes > 80 * 1024);
    var rendered = try outcome.ok.render(allocator);
    defer rendered.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "ReadArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "PLUGIN_HEAD-") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "-PLUGIN_TAIL") != null);
    var recovered = try cc.tool_result_artifact.readChunk(
        allocator,
        root,
        outcome.ok.artifact.stored.id(),
        outcome.ok.artifact.stored.bytes - 32,
        32,
    );
    defer recovered.deinit();
    try std.testing.expect(std.mem.indexOf(u8, recovered.bytes, "PLUGIN_TAIL") != null);
}

test "L2 native plan mode denies process plugin before child execution" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .ok, 1000);
    defer allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;

    const bodies = [_][]const u8{ TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .plan,
        .workspace = .{ .root = root },
        .allowed_tools = &.{TOOL_NAME},
    });
    defer session.destroy() catch unreachable;
    var sink_state: u8 = 0;
    _ = try session.runText(2, "attempt process plugin", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    const marker = try std.fmt.allocPrint(allocator, "{s}/call.marker", .{root});
    defer allocator.free(marker);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, marker, .{}));
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "denied by permission rule or plan mode") != null);
}

fn dispatchOnce(runtime: *cc.agent_session.AgentRuntime, abort: ?*const cc.util_abort.AbortSignal) !cc.tool_context.ToolDispatchOutcome {
    var selection = try cc.tool_catalog.Selection.init(std.testing.allocator, &runtime.catalog, &.{TOOL_NAME});
    defer selection.deinit();
    var tool_ctx = cc.tool_context.ToolContext.simple(std.testing.allocator);
    tool_ctx.abort = abort;
    tool_ctx.tool_dispatcher = selection.dispatcher();
    return selection.dispatcher().dispatch(&tool_ctx, TOOL_NAME, "{\"text\":\"hello\"}");
}

test "process timeout kills and reaps the child group" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .timeout, 100);
    defer allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    var outcome = try dispatchOnce(runtime, null);
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .host_failed);
    try std.testing.expect(std.mem.indexOf(u8, outcome.host_failed.?, "plugin_timeout") != null);

    const pid_path = try std.fmt.allocPrint(allocator, "{s}/child.pid", .{root});
    defer allocator.free(pid_path);
    const raw_pid = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, pid_path, allocator, .limited(64));
    defer allocator.free(raw_pid);
    const pid = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, raw_pid, " \r\n\t"), 10);
    try std.testing.expect(std.c.kill(pid, @enumFromInt(0)) != 0);
}

test "process crash invalid frame and output flood fail closed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    for ([_]CallMode{ .crash, .invalid_frame, .output_flood }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = try realRoot(&tmp, &root_buffer);
        const entrypoint = try createPackage(root, mode, 1000);
        defer std.testing.allocator.free(entrypoint);
        const runtime = try createRuntime(root);
        defer runtime.destroy() catch unreachable;
        var outcome = try dispatchOnce(runtime, null);
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expect(outcome == .host_failed);
    }
}

test "process plugin receives no inherited parent secret" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var secret_guard = try EnvGuard.set(std.testing.allocator, "METACODES_PLUGIN_SECRET", "must-not-cross");
    defer secret_guard.restore();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .env_probe, 1000);
    defer std.testing.allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    var outcome = try dispatchOnce(runtime, null);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqualStrings("process-plugin-ok", outcome.ok.@"inline".bytes);
}

test "oversized process request fails before child execution" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .ok, 1000);
    defer allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    var selection = try cc.tool_catalog.Selection.init(allocator, &runtime.catalog, &.{TOOL_NAME});
    defer selection.deinit();
    var tool_ctx = cc.tool_context.ToolContext.simple(allocator);
    tool_ctx.tool_dispatcher = selection.dispatcher();
    const text = try allocator.alloc(u8, 3000);
    defer allocator.free(text);
    @memset(text, 'a');
    const args = try std.fmt.allocPrint(allocator, "{{\"text\":\"{s}\"}}", .{text});
    defer allocator.free(args);
    var outcome = try selection.dispatcher().dispatch(&tool_ctx, TOOL_NAME, args);
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .host_failed);
    try std.testing.expect(std.mem.indexOf(u8, outcome.host_failed.?, "plugin_request_too_large") != null);
    const marker = try std.fmt.allocPrint(allocator, "{s}/call.marker", .{root});
    defer allocator.free(marker);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, marker, .{}));
}

test "handshake input schema required field is enforced before process execution" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .ok, 1000);
    defer allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    var selection = try cc.tool_catalog.Selection.init(allocator, &runtime.catalog, &.{TOOL_NAME});
    defer selection.deinit();
    var tool_ctx = cc.tool_context.ToolContext.simple(allocator);
    tool_ctx.tool_dispatcher = selection.dispatcher();
    try std.testing.expectError(
        error.MissingRequiredField,
        selection.dispatcher().dispatch(&tool_ctx, TOOL_NAME, "{}"),
    );
    const marker = try std.fmt.allocPrint(allocator, "{s}/call.marker", .{root});
    defer allocator.free(marker);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, marker, .{}));
}

test "post-stage process binary mutation fails closed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .ok, 1000);
    defer std.testing.allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = entrypoint, .data = "#!/bin/sh\nexit 0\n" });
    var outcome = try dispatchOnce(runtime, null);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .host_failed);
    try std.testing.expect(std.mem.indexOf(u8, outcome.host_failed.?, "plugin_entrypoint_hash_mismatch") != null);
}

test "handshake identity mismatch prevents snapshot publication" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .bad_handshake, 1000);
    defer std.testing.allocator.free(entrypoint);
    const packages = [_]cc.agent_session.ProcessPlugin{.{ .root = root, .layer = .session }};
    try std.testing.expectError(
        error.InvalidHandshake,
        cc.agent_session.AgentRuntime.create(std.testing.allocator, .{
            .builtin_tools = &.{},
            .process_plugins = &packages,
        }),
    );
}

test "AbortSignal interrupts a running process plugin" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try realRoot(&tmp, &root_buffer);
    const entrypoint = try createPackage(root, .timeout, 5000);
    defer std.testing.allocator.free(entrypoint);
    const runtime = try createRuntime(root);
    defer runtime.destroy() catch unreachable;
    var signal = cc.util_abort.AbortSignal.init();
    const Aborter = struct {
        fn run(target: *cc.util_abort.AbortSignal) void {
            psync.sleepMs(50);
            target.abort(.user_interrupt);
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&signal});
    defer thread.join();
    try std.testing.expectError(error.Aborted, dispatchOnce(runtime, &signal));
}
