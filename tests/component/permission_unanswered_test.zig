//! L2 (#463): a permission prompt that ended with nobody's answer reaches the
//! model as what happened, never as "user declined".
//!
//! The PermissionContext is the one AgentSession builds (default mode,
//! `no_interactive_prompt`, a requester attached). A dynamic `.execute` tool
//! makes default mode ask; the scripted requester ends the prompt one way per
//! case. Each case checks, against a loopback provider, that the Run ends
//! normally, the tool never runs, and the tool_result the provider's second
//! request carries, byte for byte. A real Deny keeps its exact bytes.
//!
//! Cross-module: agent_loop + permission/prompt + protocol/ui_request +
//! tool_error + the Anthropic client.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const ui_request = cc.ui_request;
const writer_backend = cc.writer_backend;

const TOOL = "probe463_exec";

const TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_463\",\"name\":\"" ++ TOOL ++ "\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

var tool_runs: usize = 0;

fn probeExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    tool_runs += 1;
    return ctx.allocator.dupe(u8, "ran");
}

/// Ends the permission request the way `result` says; `.answered` writes
/// `response`.
const Scripted = struct {
    result: anyerror!ui_request.RequestOutcome,
    response: ui_request.UiResponse = .{ .permission = .deny_once },
    calls: usize = 0,

    fn request(
        raw: *anyopaque,
        _: ui_request.SessionId,
        _: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *Scripted = @ptrCast(@alignCast(raw));
        if (req.* != .permission) return .unavailable;
        self.calls += 1;
        const outcome = try self.result;
        if (outcome == .answered) out.* = self.response;
        return outcome;
    }
};

fn errorJson(comptime detail: []const u8, comptime recoverable: []const u8) []const u8 {
    return "{\"error\":{\"code\":\"permission_denied\",\"category\":\"safety\",\"detail\":\"" ++ detail ++ "\",\"recoverable\":" ++ recoverable ++ "}}";
}

/// `json` as it appears inside a JSON string of the provider request. Owned.
fn escaped(json: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, std.testing.allocator, json, "\"", "\\\"");
}

/// Runs one turn that calls the tool under `requester` (null: none
/// attached) and returns the provider's second request body, owned.
fn runCase(requester: ?*Scripted) ![]u8 {
    const a = std.testing.allocator;
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register(TOOL, "Run a probe command", &.{}, probeExec, null, false);
    dyn.entries.items[dyn.entries.items.len - 1].category = .execute;

    const bodies = [_][]const u8{ TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "run the probe");

    // As AgentSession configures it (src/core/agent_session.zig).
    var perm = cc.permission.createContext(.default, a);
    perm.no_interactive_prompt = true;
    if (requester) |scripted| perm.ui_requester = .{ .ctx = scripted, .requestFn = Scripted.request };
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    tool_runs = 0;
    const result = try agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{
        .max_turns = 3,
        .dyn_registry = &dyn,
    }, &be, a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), tool_runs);
    if (requester) |scripted| try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    return a.dupe(u8, server.requestAt(1).?.body());
}

fn expectModelRead(requester: ?*Scripted, json: []const u8) !void {
    const body = try runCase(requester);
    defer std.testing.allocator.free(body);
    const needle = try escaped(json);
    defer std.testing.allocator.free(needle);
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print("expected tool_result {s}\nin request {s}\n", .{ json, body });
        return error.TestUnexpectedResult;
    }
    // Whatever the cause, never a refusal the user did not give.
    if (std.mem.indexOf(u8, json, "user declined") == null)
        try std.testing.expect(std.mem.indexOf(u8, body, "user declined") == null);
}

test "L2 #463 a real Deny still reads \"user declined '<tool>' via prompt\", byte for byte" {
    var deny = Scripted{ .result = .answered, .response = .{ .permission = .deny_once } };
    try expectModelRead(&deny, errorJson("user declined '" ++ TOOL ++ "' via prompt", "false"));
}

test "L2 #463 a permission request that timed out reads as unanswered and recoverable" {
    var timed_out = Scripted{ .result = error.UiRequestTimedOut };
    try expectModelRead(&timed_out, errorJson("'" ++ TOOL ++ "' did not run: nobody answered its permission request in time. The user did not decline it; you may offer to ask again.", "true"));
}

test "L2 #463 a permission request an interrupt or close cancelled reads as cancelled and recoverable" {
    var cancelled = Scripted{ .result = error.UiRequestCancelled };
    try expectModelRead(&cancelled, errorJson("'" ++ TOOL ++ "' did not run: an interrupt or a close cancelled its permission request before anyone answered. The user did not decline it; you may offer to ask again.", "true"));
}

test "L2 #463 an unreadable answer reads as unreadable" {
    var unreadable = Scripted{ .result = error.UiAnswerUnreadable };
    try expectModelRead(&unreadable, errorJson("'" ++ TOOL ++ "' was denied: an answer to its permission request arrived but could not be read. This is not the user's decision.", "false"));
}

test "L2 #463 a requester that answers .pending or .unavailable, or none under no_interactive_prompt: nobody to ask" {
    const nobody = errorJson("'" ++ TOOL ++ "' was denied without asking: this session has no way to ask for permission and wait for the answer. This is not the user's decision; the user never saw the request.", "false");
    var pending = Scripted{ .result = .pending };
    try expectModelRead(&pending, nobody);
    var unavailable = Scripted{ .result = .unavailable };
    try expectModelRead(&unavailable, nobody);
    // Headless runs: `no_interactive_prompt` and no requester at all.
    try expectModelRead(null, nobody);
}

test "L2 #463 a requester that fails reads as a failed request" {
    var failed = Scripted{ .result = error.HostUiFailed };
    try expectModelRead(&failed, errorJson("'" ++ TOOL ++ "' was denied: its permission request failed before anyone answered. This is not the user's decision.", "false"));
}
