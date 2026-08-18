//! Library-level completion facade over the neutral Provider vtable.
//!
//! This module deliberately does not own an HTTP client, AgentLoop policy, or
//! product semantics. It is a thin capability surface for independent model
//! completions; AgentRuntime and consumers may use it without duplicating the
//! provider transport layer.

const std = @import("std");
const provider_mod = @import("provider.zig");
const stream_mod = @import("stream.zig");
const types = @import("../types.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const ApiResponse = provider_mod.ApiResponse;
pub const StreamHandle = provider_mod.StreamHandle;
pub const StreamEvent = stream_mod.StreamEvent;
pub const Capability = provider_mod.Capability;

/// A no-tools, message-to-model completion request. Tool orchestration remains
/// an AgentRuntime concern; server-tool observations still flow through the
/// neutral StreamEvent surface when a provider emits them.
pub const CompletionRequest = struct {
    messages: []const types.ApiMessage,
    system: ?[]const u8 = null,
    model_override: ?[]const u8 = null,
    abort: ?*const AbortSignal = null,
    user_query: []const u8 = "",
};

/// Read-only provider identity/capability observations needed by consumers
/// that must bind evidence to the exact model request.
pub const ProviderInfo = struct {
    model: []const u8,
    max_tokens: u32,
    max_input_tokens: u32,
    provider: provider_mod.Provider,

    pub fn supports(self: ProviderInfo, capability: Capability) bool {
        return self.provider.supports(capability);
    }
};

pub const CompletionRuntime = struct {
    provider: provider_mod.Provider,

    pub fn init(provider: provider_mod.Provider) CompletionRuntime {
        return .{ .provider = provider };
    }

    /// Complete without entering AgentLoop or tool orchestration.
    ///
    /// The Provider non-streaming vtable has no abort slot. Reject fields that
    /// only have meaning on the streaming path instead of silently discarding
    /// a caller's cancellation/query intent.
    pub fn complete(self: *const CompletionRuntime, request: CompletionRequest) !ApiResponse {
        if (request.abort != null) return error.CompletionAbortUnsupported;
        if (request.user_query.len != 0) return error.CompletionUserQueryUnsupported;
        return self.provider.sendWithModel(
            request.messages,
            request.system,
            null,
            request.model_override,
        );
    }

    /// Open the existing neutral provider stream. The returned handle and all
    /// owned StreamEvent payloads retain the api_stream ownership contract.
    pub fn stream(self: *const CompletionRuntime, request: CompletionRequest) !StreamHandle {
        return self.provider.sendStream(
            request.messages,
            request.system,
            null,
            request.abort,
            request.model_override,
            null,
            request.user_query,
        );
    }

    pub fn providerInfo(self: *const CompletionRuntime) ProviderInfo {
        return .{
            .model = self.provider.model(),
            .max_tokens = self.provider.maxTokens(),
            .max_input_tokens = self.provider.maxInputTokens(),
            .provider = self.provider,
        };
    }
};

test "CompletionRuntime forwards no-tools contract and model override" {
    const Recorder = struct {
        complete_called: bool = false,
        stream_called: bool = false,
        complete_tools_null: bool = false,
        stream_tools_null: bool = false,
        stream_tool_choice_null: bool = false,
        complete_model_override: ?[]const u8 = null,
        stream_model_override: ?[]const u8 = null,
        stream_user_query: []const u8 = "",

        fn model(_: *anyopaque) []const u8 {
            return "test-model";
        }
        fn sendStream(
            ctx: *anyopaque,
            _: []const types.ApiMessage,
            _: ?[]const u8,
            tools: ?[]const @import("../json.zig").ToolDefinition,
            _: ?*const AbortSignal,
            model_override: ?[]const u8,
            tool_choice: ?@import("../json.zig").ToolChoice,
            user_query: []const u8,
        ) anyerror!StreamHandle {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.stream_called = true;
            self.stream_tools_null = tools == null;
            self.stream_tool_choice_null = tool_choice == null;
            self.stream_model_override = model_override;
            self.stream_user_query = user_query;
            return .{
                .ctx = ctx,
                .nextFn = next,
                .deinitFn = deinit,
                .stopReasonFn = stopReason,
                .requestIdFn = requestId,
            };
        }
        fn next(_: *anyopaque) anyerror!?StreamEvent {
            return null;
        }
        fn deinit(_: *anyopaque) void {}
        fn stopReason(_: *anyopaque) stream_mod.StopReason {
            return .end_turn;
        }
        fn requestId(_: *anyopaque) @import("../util/log.zig").RequestId {
            return .{ .bytes = [_]u8{0} ** 12 };
        }
        fn sendStreamRetry(
            _: *anyopaque,
            _: []const types.ApiMessage,
            _: ?[]const u8,
            _: ?[]const @import("../json.zig").ToolDefinition,
            _: ?*const AbortSignal,
            _: ?[]const u8,
            _: ?@import("../json.zig").ToolChoice,
            _: u32,
            _: u64,
            _: ?provider_mod.RetryReporter,
            _: []const u8,
        ) anyerror!StreamHandle {
            return error.UnexpectedTestCall;
        }
        fn send(
            ctx: *anyopaque,
            _: []const types.ApiMessage,
            _: ?[]const u8,
            tools: ?[]const @import("../json.zig").ToolDefinition,
            model_override: ?[]const u8,
        ) anyerror!ApiResponse {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.complete_called = true;
            self.complete_tools_null = tools == null;
            self.complete_model_override = model_override;
            return .{};
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 1;
        }
        fn maxInputTokens(_: *anyopaque) u32 {
            return 1;
        }
        fn reasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
            return null;
        }
        fn supports(_: *anyopaque, _: provider_mod.Capability) bool {
            return false;
        }

        fn provider(self: *@This()) provider_mod.Provider {
            return .{
                .ctx = @ptrCast(self),
                .modelFn = model,
                .sendStreamFn = sendStream,
                .sendStreamRetryFn = sendStreamRetry,
                .sendFn = send,
                .maxTokensFn = maxTokens,
                .maxInputTokensFn = maxInputTokens,
                .reasoningEffortFn = reasoningEffort,
                .supportsFn = supports,
            };
        }
    };

    var recorder = Recorder{};
    const runtime = CompletionRuntime.init(recorder.provider());
    const messages: []const types.ApiMessage = &.{};

    _ = try runtime.complete(.{ .messages = messages, .model_override = "override" });
    try std.testing.expect(recorder.complete_called);
    try std.testing.expect(recorder.complete_tools_null);
    try std.testing.expectEqualStrings("override", recorder.complete_model_override.?);

    var stream = try runtime.stream(.{
        .messages = messages,
        .model_override = "override-stream",
        .user_query = "query",
    });
    defer stream.deinit();
    try std.testing.expect(recorder.stream_called);
    try std.testing.expect(recorder.stream_tools_null);
    try std.testing.expect(recorder.stream_tool_choice_null);
    try std.testing.expectEqualStrings("override-stream", recorder.stream_model_override.?);
    try std.testing.expectEqualStrings("query", recorder.stream_user_query);

    const info = runtime.providerInfo();
    try std.testing.expectEqualStrings("test-model", info.model);
    try std.testing.expectEqual(@as(u32, 1), info.max_tokens);
    try std.testing.expectEqual(@as(u32, 1), info.max_input_tokens);
    try std.testing.expect(!info.supports(.web_search));
}

test "CompletionRuntime rejects unsupported non-streaming fields" {
    const Recorder = struct {
        fn model(_: *anyopaque) []const u8 {
            return "test-model";
        }
        fn sendStream(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const @import("../json.zig").ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?@import("../json.zig").ToolChoice, _: []const u8) anyerror!StreamHandle {
            return error.UnexpectedTestCall;
        }
        fn sendStreamRetry(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const @import("../json.zig").ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?@import("../json.zig").ToolChoice, _: u32, _: u64, _: ?provider_mod.RetryReporter, _: []const u8) anyerror!StreamHandle {
            return error.UnexpectedTestCall;
        }
        fn send(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const @import("../json.zig").ToolDefinition, _: ?[]const u8) anyerror!ApiResponse {
            return .{};
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 1;
        }
        fn maxInputTokens(_: *anyopaque) u32 {
            return 1;
        }
        fn reasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
            return null;
        }
        fn supports(_: *anyopaque, _: provider_mod.Capability) bool {
            return false;
        }
    };

    var state: u8 = 0;
    const provider = provider_mod.Provider{
        .ctx = @ptrCast(&state),
        .modelFn = Recorder.model,
        .sendStreamFn = Recorder.sendStream,
        .sendStreamRetryFn = Recorder.sendStreamRetry,
        .sendFn = Recorder.send,
        .maxTokensFn = Recorder.maxTokens,
        .maxInputTokensFn = Recorder.maxInputTokens,
        .reasoningEffortFn = Recorder.reasoningEffort,
        .supportsFn = Recorder.supports,
    };
    const runtime = CompletionRuntime.init(provider);
    var abort = AbortSignal.init();
    try std.testing.expectError(error.CompletionAbortUnsupported, runtime.complete(.{ .messages = &.{}, .abort = &abort }));
    try std.testing.expectError(error.CompletionUserQueryUnsupported, runtime.complete(.{ .messages = &.{}, .user_query = "query" }));
}
