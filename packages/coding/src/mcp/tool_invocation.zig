//! One MCP tool call running under an Agent's `ToolContext`, as the product's
//! tool registry makes it. Permission, sandbox and budget decisions are the
//! kernel's (`core/tool_exec`) and happen before this; the context supplies the
//! Session artifact root, the model-derived result budget and the Run's abort
//! signal, and a sealed result reaches the batch commit boundary like any other.
//!
//! The AgentCore overlay (`agentcore/mcp_session.zig`) makes the same call
//! through `runtime.Client.callToolBody`: both end in `McpClient.invokeTool`,
//! under the same kernel. They differ only in how they present a failure:
//! AgentCore as a `host_failed` JSON diagnostic (its public contract), the
//! product as a tool error the model reads, saying when the call may have run.

const std = @import("std");
const client_mod = @import("client.zig");
const canonical = @import("canonical.zig");
const transport_mod = @import("transport.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
const ToolResultBody = @import("../tools/context.zig").ToolResultBody;

const McpClient = client_mod.McpClient;

pub const Target = struct {
    name: []const u8,
    arguments_json: []const u8,
    headers: []const transport_mod.Header = &.{},
    has_output_schema: bool = false,
};

pub fn invoke(client: *McpClient, ctx: *const ToolContext, target: Target) client_mod.BodyOutcome {
    return client.invokeTool(ctx.allocator, .{
        .name = target.name,
        .arguments_json = target.arguments_json,
        .artifact_root = ctx.artifact_root,
        .budget = ctx.result_budget,
        .abort = ctx.abort,
        .headers = target.headers,
        .has_output_schema = target.has_output_schema,
    });
}

/// `invoke` for a dynamic-registry tool. A call that left with no answer says
/// so: the model must not take a retry to be free.
pub fn execute(out: *ToolResultBody, client: *McpClient, ctx: *const ToolContext, target: Target) anyerror!void {
    const outcome = invoke(client, ctx, target);
    if (outcome == .failed) reportIndeterminate(ctx, outcome.failed, target.name);
    try client_mod.admitOutcome(out, ctx.allocator, outcome);
}

fn reportIndeterminate(ctx: *const ToolContext, failed: client_mod.BodyFailure, name: []const u8) void {
    if (failed.disposition != .indeterminate or failed.failure == .cancelled) return;
    const slot = ctx.error_detail orelse return;
    slot.* = std.fmt.allocPrint(
        ctx.allocator,
        "MCP tool '{s}' got no answer ({s}). The server may have executed the call: check its effect before repeating it.",
        .{ name, @errorName(failed.err) },
    ) catch null;
}

test "an indeterminate failure tells the model; a refused one does not" {
    const allocator = std.testing.allocator;
    var detail: ?[]const u8 = null;
    defer if (detail) |text| allocator.free(text);
    var ctx = ToolContext.simple(allocator);
    ctx.error_detail = &detail;
    reportIndeterminate(&ctx, .{ .failure = .auth_error, .disposition = .not_delivered, .err = error.McpAuthRequired }, "t");
    try std.testing.expect(detail == null);
    reportIndeterminate(&ctx, .{ .failure = .cancelled, .disposition = .indeterminate, .err = error.Aborted }, "t");
    try std.testing.expect(detail == null);
    reportIndeterminate(&ctx, .{ .failure = .timeout, .disposition = .indeterminate, .err = error.McpRequestTimeout }, "t");
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "may have executed") != null);
    try std.testing.expect(canonical.Disposition.indeterminate != .answered);
}
