const std = @import("std");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;
const Server = @import("mock_server.zig").Server;

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m4\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"artifact done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Probe = struct {
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    saw_read_result: bool = false,
    saw_host_result: bool = false,
    saw_final_text: bool = false,

    fn event(raw: ?*anyopaque, _: ?*wire.SessionHandle, _: u64, json_view: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.CALLBACK_FATAL));
        const json = sdk.borrowedBytes(json_view) catch return wire.CALLBACK_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, json) catch return wire.CALLBACK_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known_event| switch (known_event) {
                .tool_result => |result| {
                    if (std.mem.eql(u8, result.name, "Read") and !result.is_error and
                        std.mem.indexOf(u8, result.content, "artifact-read-ok") != null)
                        self.saw_read_result = true;
                    if (std.mem.eql(u8, result.name, "HostEcho") and !result.is_error and
                        std.mem.eql(u8, result.content, "artifact-host-ok"))
                        self.saw_host_result = true;
                },
                .text_chunk => |text| {
                    if (std.mem.eql(u8, text, "artifact done")) self.saw_final_text = true;
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.CALLBACK_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, _: ?*wire.SessionHandle, request: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        const encoded = sdk.borrowedBytes(request) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const questions = switch (parsed.value) {
            .ask_question => |questions| questions,
            else => return wire.UI_FATAL,
        };
        if (questions.len != 1 or !std.mem.eql(u8, questions[0].question, "Continue?") or
            questions[0].options.len != 2 or !std.mem.eql(u8, questions[0].options[0].label, "Yes"))
            return wire.UI_FATAL;
        self.ui_calls += 1;
        const answers = [_][]const u8{"Yes"};
        const response = sdk.encodeUiResponse(std.heap.c_allocator, parsed.value, .{ .answers = &answers }) catch return wire.UI_FATAL;
        (out orelse {
            std.heap.c_allocator.free(response);
            return wire.UI_FATAL;
        }).* = .{ .ptr = response.ptr, .len = response.len };
        return wire.UI_ANSWERED;
    }

    fn uiRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.ui_releases += 1;
        if (out) |value| {
            const len = std.math.cast(usize, value.len) orelse return;
            if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..len]);
            value.* = .{ .ptr = null, .len = 0 };
        }
    }

    fn host(raw: ?*anyopaque, _: wire.BytesViewV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        const Args = struct { text: []const u8 };
        const encoded = sdk.borrowedBytes(args) catch return wire.HOST_FAILED;
        const parsed = std.json.parseFromSlice(Args, std.heap.c_allocator, encoded, .{}) catch return wire.HOST_FAILED;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.text, "hello")) return wire.HOST_FAILED;
        self.host_calls += 1;
        const result = "artifact-host-ok";
        (out orelse return wire.HOST_FAILED).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn hostRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.host_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const api = try sdk.Api.discover();
    if (sdk.metacodes_agentcore_get_api(2) != null) return error.UnexpectedAbi;

    var name_buf: [128]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&name_buf, "metacodes-agentcore-{d}.txt", .{std.c.getpid()});
    var path_buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/{s}", .{file_name});
    defer _ = std.c.unlink(file_path.ptr);
    try writeFile(file_path.ptr, "artifact-read-ok");
    // Source-free proof: the model supplies a relative file path and the
    // binary facade resolves it against workspace_root, not process cwd.
    const read_sse = try readToolSse(a, file_name);
    const bodies = [_][]const u8{ ASK_SSE, read_sse, HOST_SSE, FINAL_SSE };
    const server = try Server.start(&bodies);
    defer server.stop();
    const url = try server.url(a);

    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read") };
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Host echo"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = Probe.host,
        .release_result = Probe.hostRelease,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = wire.RuntimeConfigV1{
        .struct_size = @sizeOf(wire.RuntimeConfigV1),
        .reserved0 = 0,
        .builtin_tools = &builtins,
        .builtin_tool_count = builtins.len,
        .host_tools = @ptrCast(&host),
        .host_tool_count = 1,
        .reserved = [_]u64{0} ** 4,
    };
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try expectStatus(.ok, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic), diagnostic);
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read"), sdk.bytesView("HostEcho") };
    var config = wire.SessionConfigV1{
        .struct_size = @sizeOf(wire.SessionConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_BYPASS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("artifact-key"),
        .model = sdk.bytesView("artifact-model"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView("/tmp"),
        .workspace_home = sdk.bytesView("/tmp"),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .reserved = [_]u64{0} ** 4,
    };
    var callbacks = wire.SessionCallbacksV1{
        .struct_size = @sizeOf(wire.SessionCallbacksV1),
        .reserved0 = 0,
        .ctx = &probe,
        .on_event = Probe.event,
        .on_ui_request = Probe.ui,
        .release_response = Probe.uiRelease,
        .reserved = [_]u64{0} ** 4,
    };
    var session: ?*wire.SessionHandle = null;
    try expectStatus(.ok, api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic), diagnostic);
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 6, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try expectStatus(.ok, api.sessionRun()(session, 1, sdk.bytesView("exercise bundle"), &options, &result, &diagnostic), diagnostic);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or result.tool_calls != 3) return error.UnexpectedRunResult;
    if (probe.ui_calls != 1 or probe.ui_releases != 1 or probe.host_calls != 1 or probe.host_releases != 1) return error.CallbackContractFailed;
    if (!probe.saw_read_result or !probe.saw_host_result or !probe.saw_final_text) return error.MissingCoreEvent;
    try expectStatus(.ok, api.sessionDestroy()(session, &diagnostic), diagnostic);
    session = null;
    try expectStatus(.ok, api.runtimeDestroy()(runtime, &diagnostic), diagnostic);
    runtime = null;
    std.debug.print("AgentCore source-free consumer: real tool, Host tool, Host UI and events OK\n", .{});
}

fn readToolSse(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn writeFile(path: [*:0]const u8, content: []const u8) !void {
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, content.ptr, content.len) != content.len) return error.WriteFailed;
}

fn expectStatus(expected: sdk.Status, actual_code: u32, diagnostic: wire.OwnedBytesV1) !void {
    const actual = sdk.Status.fromCode(actual_code) catch return error.UnknownStatus;
    if (actual == expected) return;
    const message = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "invalid diagnostic";
    std.debug.print("AgentCore status {s}, expected {s}: {s}\n", .{ @tagName(actual), @tagName(expected), message });
    return error.UnexpectedStatus;
}
