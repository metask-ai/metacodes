//! Amazon Bedrock Converse transport (`bedrock_converse` wire).
//!
//! Integration notes — endpoints, auth, thinking fields per hosted vendor,
//! reasoning passback, cache points, and their sources — are the header of
//! `src/api/dialects/bedrock.zig`. This file is the transport:
//!
//! - **Request**: `POST {base}/model/{modelId}/converse-stream`, the model id
//!   percent-encoded into the path (ids carry `:` and ARNs carry `/`). JSON
//!   body: `messages`, `system`, `inferenceConfig.maxTokens`, `toolConfig`,
//!   and the dialect's `additionalModelRequestFields`.
//! - **Auth**: a Bedrock API key as `Authorization: Bearer` (the profile's
//!   scheme). SigV4 is not implemented.
//! - **Response**: an AWS event stream (`aws_event_stream.zig`), one JSON
//!   payload per frame, named by the `:event-type` header; failures arrive as
//!   `:message-type exception` frames.
//!
//! Thinking passback: Claude on Bedrock requires the previous assistant turn's
//! reasoning blocks, signatures intact and in order, while a tool loop is in
//! progress. The stream hands each signed `reasoningContent` block to the
//! agent loop as a `reasoning_item` (its Converse JSON, verbatim), which the
//! conversation keeps — in the transcript and the AgentCore checkpoint too —
//! at the head of its assistant message; the serializer writes the same bytes
//! back for the same model. Nothing about a conversation lives in this client.

const std = @import("std");
const http = std.http;
const sync = @import("platform").sync;
const connection_gate = @import("connection_gate.zig");
const ResponseStatus = @import("http_status.zig").ResponseStatus;
const http_status = @import("http_status.zig");
const http_connection = @import("http_connection.zig");
const no_redirects = http_status.no_redirects;
const log = @import("../util/log.zig");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
const util_json = @import("../util/json.zig");
const api_stream = @import("stream.zig");
const provider_mod = @import("provider.zig");
const client_mod = @import("../client.zig");
const model_error = @import("model_error.zig");
const liveness_reader = @import("liveness_reader.zig");
const capability = @import("capability.zig");
const request_overrides = @import("request_overrides.zig");
const dialect_mod = @import("dialect.zig");
const bedrock_dialect = @import("dialects/bedrock.zig");
const catalog_mod = @import("catalog.zig");
const image_capability = @import("image_capability.zig");
const credential_mod = @import("credential_cell.zig");
const auth_header_mod = @import("auth_header.zig");
const event_stream = @import("aws_event_stream.zig");
const secure = @import("../util/secure.zig");
const model_limits_table = @import("../util/model.zig");
const error_class = @import("error_class.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const model_context_mod = @import("../app/model_context.zig");

const StreamEvent = api_stream.StreamEvent;
const StreamHandle = api_stream.StreamHandle;
const StopReason = api_stream.StopReason;
const UsageDelta = api_stream.UsageDelta;

pub const DEFAULT_BEDROCK_BASE = "https://bedrock-runtime.us-east-1.amazonaws.com";

/// How a replayable reasoning block starts: the Converse content block, as the
/// stream wrote it into a `reasoning_item`. Anything else in a `reasoning_item`
/// (an OpenAI Responses item, say) is not this wire's and is never sent.
pub const REASONING_ITEM_PREFIX = "{\"reasoningContent\":";

pub const BedrockClient = struct {
    allocator: std.mem.Allocator,
    credential: credential_mod.Credential,
    /// Origin of the region's runtime endpoint; the path is built per request.
    base_url: []const u8,
    model: []const u8,
    http_client: http.Client,
    abort_registry: provider_mod.RequestAbortRegistry = .{},
    stream_idle_timeout_ms: u64 = client_mod.DEFAULT_STREAM_IDLE_TIMEOUT_MS,
    stream_body_idle_timeout_ms: ?u64 = null,
    /// Null: the model's default from `util/model.zig` (bare model name).
    max_tokens_override: ?u32 = null,
    model_context: ?*const model_context_mod.ModelContext = null,
    context_window: u32 = 200_000,
    reasoning_effort: ?types.ReasoningEffort = null,
    overrides: request_overrides.RequestOverrides = .{},
    auth_scheme: ?auth_header_mod.AuthScheme = null,
    dialect_resolver: dialect_mod.Resolver = .{},
    /// The vendor the route (or the bound model's entry) declares for the
    /// hosted model; neither reads it from the model id.
    declared_dialect: dialect_mod.DialectDeclaration = .{},
    catalog: ?catalog_mod.Catalog = null,
    host_capabilities: image_capability.Declarations = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, base_url: ?[]const u8) BedrockClient {
        return .{
            .allocator = allocator,
            .credential = .{ .fixed = api_key },
            .base_url = base_url orelse DEFAULT_BEDROCK_BASE,
            .model = model,
            .http_client = http.Client{ .allocator = allocator, .io = io },
            .stream_idle_timeout_ms = client_mod.streamIdleTimeoutMsFromEnv(),
            .stream_body_idle_timeout_ms = client_mod.streamBodyIdleTimeoutMsFromEnv(),
        };
    }

    pub fn deinit(self: *BedrockClient) void {
        self.abort_registry.deinit(self.allocator);
        self.http_client.deinit();
        if (self.catalog) |*catalog| catalog.deinit();
        self.host_capabilities.deinit();
    }

    pub fn provider(self: *BedrockClient) provider_mod.Provider {
        return .{
            .ctx = @ptrCast(self),
            .modelFn = &pModel,
            .sendStreamFn = &pSendStream,
            .sendStreamRetryFn = &pSendStreamRetry,
            .sendFn = &pSend,
            .cancelFn = &pCancel,
            .maxTokensFn = &pMaxTokens,
            .maxInputTokensFn = &pMaxInputTokens,
            .maxTokensForFn = &pMaxTokensFor,
            .maxInputTokensForFn = &pMaxInputTokensFor,
            .reasoningEffortFn = &pReasoningEffort,
            .setReasoningEffortFn = &pSetReasoningEffort,
            .requestOverridesFn = &pRequestOverrides,
            .setRequestOverridesFn = &pSetRequestOverrides,
            .supportsFn = &pSupports,
            .supportsForModelFn = &pSupportsForModel,
            .imageInputFn = &pImageInput,
            .routeFn = &pRoute,
        };
    }

    inline fn cast(ctx: *anyopaque) *BedrockClient {
        return @ptrCast(@alignCast(ctx));
    }
    fn pModel(ctx: *anyopaque) []const u8 {
        return cast(ctx).model;
    }
    fn pRoute(ctx: *anyopaque) ?provider_mod.ProviderRoute {
        const self = cast(ctx);
        return .{
            .kind = .bedrock,
            .base_url = self.base_url,
            .model = self.model,
            .credential = self.credential.lendable() orelse return null,
            .auth_scheme = self.auth_scheme,
        };
    }
    fn pRequestOverrides(ctx: *anyopaque) request_overrides.RequestOverrides {
        const self = cast(ctx);
        var o = self.overrides;
        if (o.reasoning_effort == null) o.reasoning_effort = self.reasoning_effort;
        return o;
    }
    fn pSetRequestOverrides(ctx: *anyopaque, o: request_overrides.RequestOverrides) void {
        cast(ctx).overrides = o;
        if (o.reasoning_effort) |e| cast(ctx).reasoning_effort = e;
    }
    fn pMaxTokens(ctx: *anyopaque) u32 {
        return pMaxTokensFor(ctx, cast(ctx).model);
    }
    fn pMaxInputTokens(ctx: *anyopaque) u32 {
        return pMaxInputTokensFor(ctx, cast(ctx).model);
    }
    fn pMaxTokensFor(ctx: *anyopaque, model: []const u8) u32 {
        return cast(ctx).maxTokensFor(model);
    }
    fn pMaxInputTokensFor(ctx: *anyopaque, model: []const u8) u32 {
        const self = cast(ctx);
        if (self.model_context) |mc| if (mc.windowFor(model)) |w| return w;
        return self.context_window;
    }
    fn pReasoningEffort(ctx: *anyopaque) ?types.ReasoningEffort {
        return cast(ctx).reasoning_effort;
    }
    fn pSetReasoningEffort(ctx: *anyopaque, effort: ?types.ReasoningEffort) void {
        cast(ctx).reasoning_effort = effort;
    }
    fn pSupports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
        return cast(ctx).supportsForModel(cap, cast(ctx).model);
    }
    fn pSupportsForModel(ctx: *anyopaque, cap: provider_mod.Capability, model: []const u8) bool {
        return cast(ctx).supportsForModel(cap, model);
    }
    fn pImageInput(ctx: *anyopaque, model: []const u8) image_capability.Resolution {
        const profile = cast(ctx).dialectFor(model).profileFor(.bedrock, model);
        return .{ .supported = profile.supports_image_input, .source = profile.image_input_source };
    }
    fn pSend(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!provider_mod.ApiResponse {
        _ = ctx;
        _ = messages;
        _ = system;
        _ = tools;
        _ = model_override;
        return error.NotImplemented; // non-streaming Converse is not wired (compact keeps recent)
    }
    fn pCancel(ctx: *anyopaque, signal: *const AbortSignal) void {
        cast(ctx).abort_registry.cancel(signal);
    }
    fn pSendStreamRetry(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, max_retries: u32, retry_base_ms: u64, reporter: ?provider_mod.RetryReporter, user_query: []const u8) anyerror!StreamHandle {
        _ = max_retries;
        _ = retry_base_ms;
        _ = reporter;
        return pSendStream(ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }
    fn pSendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!StreamHandle {
        _ = user_query;
        const self = cast(ctx);
        const model = model_override orelse self.model;
        var o = self.overrides;
        if (o.reasoning_effort == null) o.reasoning_effort = self.reasoning_effort;
        o.tool_choice = tool_choice;
        var report = json_mod.SerializationReport{};
        defer report.deinit(self.allocator);
        const body = try serializeConverseRequest(self.allocator, .{
            .model = model,
            .messages = messages,
            .system = system,
            .tools = tools,
            .overrides = o,
            .max_tokens = self.maxTokensFor(model),
            .dialect = self.dialectFor(model),
            .declared = self.declared_dialect.vendorFor(self.model, model),
        }, &report);
        defer self.allocator.free(body);
        const placeholder_ids = try report.placeholder_ids.toOwnedSlice(self.allocator);
        return self.doStream(model, body, abort, placeholder_ids);
    }

    pub fn maxTokensFor(self: *const BedrockClient, model: []const u8) u32 {
        if (self.max_tokens_override) |value| return value;
        return model_limits_table.limitsFor(bedrock_dialect.bareModel(model)).default;
    }

    /// The dialect for `model`, with the Host's or the catalog's image-input
    /// declaration applied.
    pub fn dialectFor(self: *const BedrockClient, model: []const u8) dialect_mod.Dialect {
        var dialect = self.dialect_resolver.resolve(.bedrock, self.declared_dialect.vendorFor(self.model, model), model);
        const from_catalog: ?bool = if (self.catalog) |*catalog| catalog.imageInputFor(model) else null;
        dialect.declareImageInput(self.host_capabilities.imageInputFor(model), from_catalog);
        return dialect;
    }

    /// The route's declared vendor decides what the dialect sends; the
    /// capability answers follow the same vendor, not a substring of the id.
    pub fn supportsForModel(self: *const BedrockClient, cap: provider_mod.Capability, model: []const u8) bool {
        const declared = self.declared_dialect.vendorFor(self.model, model);
        return switch (cap) {
            .image_input => self.dialectFor(model).profileFor(.bedrock, model).supports_image_input,
            .prompt_cache => bedrock_dialect.supportsCachePoints(declared, model),
            .extended_thinking => bedrock_dialect.supportsThinking(declared, model),
            else => capability.supports(.bedrock, model, cap),
        };
    }

    fn doStream(self: *BedrockClient, model: []const u8, body: []const u8, abort: ?*const AbortSignal, image_placeholder_ids: []const []const u8) !StreamHandle {
        errdefer self.allocator.free(image_placeholder_ids);
        const rid = log.genRequestId();
        const url = try converseStreamUrl(self.allocator, self.base_url, model);
        defer self.allocator.free(url);
        log.infoId("bedrock", rid, "POST {s} body_bytes={d} cache_mode={s}", .{ url, body.len, @import("cache.zig").modeFor(.bedrock).label() });
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        const req_ptr = try self.allocator.create(http.Client.Request);
        errdefer self.allocator.destroy(req_ptr);
        var connection_lease = try connection_gate.acquire(abort);
        defer connection_lease.release();
        const auth = self.credential.header(self.allocator, self.auth_scheme) catch |err| {
            log.errId("bedrock", rid, "auth header materialization failed: {s}", .{@errorName(err)});
            return credential_mod.requestError(err);
        };
        defer secure.free(self.allocator, auth.value);
        req_ptr.* = self.http_client.request(.POST, uri, .{
            .keep_alive = false,
            .redirect_behavior = no_redirects,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "application/vnd.amazon.eventstream" },
                .{ .name = auth.name, .value = auth.value },
            },
        }) catch |err| {
            log.errId("bedrock", rid, "request init failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        var registered = false;
        errdefer {
            if (registered) self.abort_registry.unregister(req_ptr);
            req_ptr.deinit();
        }
        try self.abort_registry.registerMonitored(self.allocator, abort, req_ptr, shutdownRequest, self.stream_idle_timeout_ms);
        registered = true;
        req_ptr.transfer_encoding = .{ .content_length = body.len };
        http_connection.sendBodyComplete(req_ptr, @constCast(body)) catch |err| {
            log.errId("bedrock", rid, "send body failed: {s}", .{@errorName(err)});
            client_mod.noteConnectFailure(err);
            return error.RequestFailed;
        };
        const response = req_ptr.receiveHead(&.{}) catch |err| {
            if (self.abort_registry.stalled(req_ptr)) |stall| {
                client_mod.reportHeadStall("bedrock", rid, stall);
                return error.TransientNetwork;
            }
            log.errId("bedrock", rid, "receiveHead failed: {s}", .{@errorName(err)});
            client_mod.noteConnectFailure(err);
            return err;
        };
        const status = ResponseStatus.capture(&response);
        client_mod.noteResponseHead(status.code, response.head, auth.value);
        connection_lease.release();
        if (!status.isOk()) {
            var location_buf: [http_status.REDIRECT_LOCATION_BYTES]u8 = undefined;
            if (http_status.copyRedirectLocation(&response, &location_buf)) |location| {
                client_mod.reportRedirect("bedrock", rid, status, location, auth.value);
                return error.RequestFailed;
            }
            var err_body: [4096]u8 = undefined;
            const body_reader = req_ptr.reader.bodyReader(err_body[0..], response.head.transfer_encoding, response.head.content_length);
            const n = body_reader.readSliceShort(err_body[0..]) catch 0;
            client_mod.reportHttpFailure("bedrock", rid, status, err_body[0..@min(n, err_body.len)], err_body.len, auth.value);
            return error.RequestFailed;
        }
        client_mod.noteRequestAccepted();
        self.abort_registry.setIdleLimit(req_ptr, client_mod.bodyIdleLimitMs(self.stream_body_idle_timeout_ms, self.stream_idle_timeout_ms, self.maxTokensFor(model)), .sse);
        const heap = try self.allocator.create(BedrockStream);
        heap.* = .{
            .allocator = self.allocator,
            .image_placeholder_ids = image_placeholder_ids,
            .request = req_ptr,
            .response = response,
            .abort = abort,
            .abort_registry = &self.abort_registry,
            .id = rid,
            .credential = client_mod.credentialPrint(auth.value),
        };
        return heap.handle();
    }
};

/// `{base}/model/{percent-encoded modelId}/converse-stream`. Only RFC 3986
/// unreserved bytes pass through: ids carry `:` and ARNs carry `/`.
pub fn converseStreamUrl(allocator: std.mem.Allocator, base_url: []const u8, model: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, std.mem.trimEnd(u8, base_url, "/"));
    try out.appendSlice(allocator, "/model/");
    for (model) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try out.append(allocator, byte);
        } else {
            var buf: [3]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "%{X:0>2}", .{byte}));
        }
    }
    try out.appendSlice(allocator, "/converse-stream");
    return out.toOwnedSlice(allocator);
}

// ── request ──────────────────────────────────────────────────────────────────

pub const ConverseRequest = struct {
    model: []const u8,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    overrides: request_overrides.RequestOverrides = .{},
    max_tokens: u32,
    dialect: dialect_mod.Dialect,
    declared: ?dialect_mod.Vendor = null,
};

const CACHE_POINT = "{\"cachePoint\":{\"type\":\"default\"}}";

/// Neutral conversation → Converse request body. Caller frees.
pub fn serializeConverseRequest(allocator: std.mem.Allocator, req: ConverseRequest, report: *json_mod.SerializationReport) ![]u8 {
    const profile = req.dialect.profileFor(.bedrock, req.model);
    const cache_points = bedrock_dialect.supportsCachePoints(req.declared, req.model);

    // Tools with a Converse form, and whether the caller's toolChoice forces one.
    var converse_tools: usize = 0;
    if (req.tools) |tools| for (tools) |t| {
        if (t.server_type == null) converse_tools += 1; // Anthropic server tools have no Converse form
    };
    const tool_choice: ?json_mod.ToolChoice = if (converse_tools > 0) req.overrides.tool_choice else null;

    // The thinking fields first: what they may share the request with decides
    // the members written before them.
    var additional: std.ArrayList(u8) = .empty;
    defer additional.deinit(allocator);
    const plan = try bedrock_dialect.serializeAdditionalFields(req.dialect, req.declared, req.model, req.overrides.reasoning_effort, .{
        .max_tokens = req.max_tokens,
        .sampling = req.overrides.temperature != null or req.overrides.top_p != null,
        .forced_tool = if (tool_choice) |tc| forcesTool(tc) else false,
    }, &additional, allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"messages\":[");
    var last_role: ?types.MessageRole = null;
    for (req.messages) |m| {
        const mark = out.items.len;
        // Two messages of one role in a row become one (a message in between
        // had nothing this wire sends): reopen the previous message's list.
        const merging = last_role == m.role;
        if (merging) {
            out.items.len -= 2; // `]}`
            try out.append(allocator, ',');
        } else {
            if (last_role != null) try out.append(allocator, ',');
            try out.appendSlice(allocator, if (m.role == .user) "{\"role\":\"user\",\"content\":[" else "{\"role\":\"assistant\",\"content\":[");
        }
        const blocks_start = out.items.len;
        try serializeContent(allocator, &out, m, req, profile, report);
        if (out.items.len == blocks_start) {
            // Converse rejects a message with no blocks; such a message carried
            // only content this wire does not send (a lone thinking block).
            if (merging) {
                out.shrinkRetainingCapacity(mark - 2);
                try out.appendSlice(allocator, "]}");
            } else {
                out.shrinkRetainingCapacity(mark);
            }
            continue;
        }
        out.items.len -= 1; // the last block's `,`
        try out.appendSlice(allocator, "]}");
        last_role = m.role;
    }
    // The conversation's own cache point, at the end of the last message, so
    // the next request of the loop reads the history back (the system and
    // tools points below cover the rest: 3 of the 4 Bedrock allows).
    if (cache_points and last_role != null) {
        out.items.len -= 2;
        try out.appendSlice(allocator, "," ++ CACHE_POINT ++ "]}");
    }
    try out.append(allocator, ']');

    var system_buf: std.ArrayList(u8) = .empty;
    defer system_buf.deinit(allocator);
    if (req.system) |sys| try system_buf.appendSlice(allocator, sys);
    try req.dialect.injectSystemMods(profile, req.overrides.reasoning_effort, &system_buf, allocator);
    try req.dialect.activateCapabilities(profile, dialect_mod.visibleCapabilities(req.tools), &system_buf, allocator);
    if (system_buf.items.len > 0) {
        try out.appendSlice(allocator, ",\"system\":[{\"text\":");
        try util_json.serializeString(system_buf.items, &out, allocator);
        try out.append(allocator, '}');
        if (cache_points) try out.appendSlice(allocator, "," ++ CACHE_POINT);
        try out.append(allocator, ']');
    }

    try out.print(allocator, ",\"inferenceConfig\":{{\"maxTokens\":{d}", .{req.max_tokens});
    if (plan.sampling) {
        if (req.overrides.temperature) |t| {
            try out.appendSlice(allocator, ",\"temperature\":");
            try util_json.serializeNumber(t, &out, allocator);
        }
        if (req.overrides.top_p) |p| {
            try out.appendSlice(allocator, ",\"topP\":");
            try util_json.serializeNumber(p, &out, allocator);
        }
    }
    try out.append(allocator, '}');

    if (converse_tools > 0) {
        try out.appendSlice(allocator, ",\"toolConfig\":{\"tools\":[");
        var first = true;
        for (req.tools.?) |t| {
            if (t.server_type != null) continue;
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, "{\"toolSpec\":{\"name\":");
            try util_json.serializeString(t.name, &out, allocator);
            try out.appendSlice(allocator, ",\"description\":");
            try util_json.serializeString(t.description, &out, allocator);
            try out.appendSlice(allocator, ",\"inputSchema\":{\"json\":");
            try @import("request.zig").serializeInputSchema(t.input_schema, &out, allocator);
            try out.appendSlice(allocator, "}}}");
        }
        if (cache_points) try out.appendSlice(allocator, "," ++ CACHE_POINT);
        try out.append(allocator, ']');
        // A model that thinks whatever is sent cannot be forced to a tool
        // (AWS: thinking supports auto and none only); it chooses itself.
        if (tool_choice) |tc| if (plan.forced_tool or !forcesTool(tc)) try serializeToolChoice(allocator, &out, tc);
        try out.append(allocator, '}');
    }

    if (additional.items.len > 0) {
        try out.appendSlice(allocator, ",\"additionalModelRequestFields\":{");
        try out.appendSlice(allocator, additional.items);
        try out.append(allocator, '}');
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// `any` / `required` / a named tool: the choices thinking cannot share a
/// request with.
fn forcesTool(tc: json_mod.ToolChoice) bool {
    return std.mem.eql(u8, tc.type, "any") or std.mem.eql(u8, tc.type, "required") or std.mem.eql(u8, tc.type, "tool");
}

fn serializeToolChoice(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tc: json_mod.ToolChoice) !void {
    if (std.mem.eql(u8, tc.type, "auto")) {
        try out.appendSlice(allocator, ",\"toolChoice\":{\"auto\":{}}");
    } else if (std.mem.eql(u8, tc.type, "any") or std.mem.eql(u8, tc.type, "required")) {
        try out.appendSlice(allocator, ",\"toolChoice\":{\"any\":{}}");
    } else if (std.mem.eql(u8, tc.type, "tool")) {
        const name = tc.name orelse return out.appendSlice(allocator, ",\"toolChoice\":{\"any\":{}}");
        try out.appendSlice(allocator, ",\"toolChoice\":{\"tool\":{\"name\":");
        try util_json.serializeString(name, out, allocator);
        try out.appendSlice(allocator, "}}");
    }
    // "none" has no Converse form: the model may call tools as with auto.
}

/// The blocks of one message, each followed by a comma (the caller trims the
/// last). Nothing for a message with no Converse content.
fn serializeContent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    m: types.ApiMessage,
    req: ConverseRequest,
    profile: dialect_mod.ModelProfile,
    report: *json_mod.SerializationReport,
) !void {
    for (m.content) |c| switch (c) {
        // Signed reasoning, verbatim, where the conversation keeps it (the
        // head of its assistant message); only this model's, only this wire's.
        .reasoning_item => |item| {
            if (m.role != .assistant) continue;
            if (!std.mem.eql(u8, item.model, req.model)) continue;
            if (!std.mem.startsWith(u8, item.json, REASONING_ITEM_PREFIX)) continue;
            try out.appendSlice(allocator, item.json);
            try out.append(allocator, ',');
        },
        .text => |t| {
            if (t.len == 0) continue; // Converse rejects a blank text block
            try out.appendSlice(allocator, "{\"text\":");
            try util_json.serializeString(t, out, allocator);
            try out.appendSlice(allocator, "},");
        },
        .image => |img| {
            if (!try req.dialect.serializeImagePart(profile, img, out, allocator)) return error.ImageInputUnsupported;
            try out.append(allocator, ',');
        },
        .tool_use => |tu| {
            try out.appendSlice(allocator, "{\"toolUse\":{\"toolUseId\":");
            try util_json.serializeString(tu.id, out, allocator);
            try out.appendSlice(allocator, ",\"name\":");
            try util_json.serializeString(tu.name, out, allocator);
            try out.appendSlice(allocator, ",\"input\":");
            const input = std.mem.trim(u8, tu.input, " \t\r\n");
            try out.appendSlice(allocator, if (input.len == 0) "{}" else input);
            try out.appendSlice(allocator, "}},");
        },
        .tool_result => |tr| {
            try out.appendSlice(allocator, "{\"toolResult\":{\"toolUseId\":");
            try util_json.serializeString(tr.tool_use_id, out, allocator);
            try out.appendSlice(allocator, ",\"content\":[");
            if (json_mod.extractImageResult(tr.content)) |img| image: {
                report.image_results += 1;
                const mark = out.items.len;
                if (try req.dialect.serializeImagePart(profile, img, out, allocator)) break :image;
                out.shrinkRetainingCapacity(mark);
                try report.notePlaceholder(allocator, tr.tool_use_id);
                var placeholder: std.ArrayList(u8) = .empty;
                defer placeholder.deinit(allocator);
                try dialect_mod.appendImageOmittedPlaceholder(img.media_type, &placeholder, allocator);
                try out.appendSlice(allocator, "{\"text\":");
                try util_json.serializeString(placeholder.items, out, allocator);
                try out.append(allocator, '}');
            } else {
                try out.appendSlice(allocator, "{\"text\":");
                // An empty result is still a result; Converse wants text in it.
                try util_json.serializeString(if (tr.content.len == 0) "(empty)" else tr.content, out, allocator);
                try out.append(allocator, '}');
            }
            try out.append(allocator, ']');
            if (tr.is_error) try out.appendSlice(allocator, ",\"status\":\"error\"");
            try out.appendSlice(allocator, "}},");
        },
        // Unsigned thinking text cannot be replayed on Bedrock; the signed
        // block travels as the `reasoning_item` above.
        .thinking => {},
    };
}

// ── response ─────────────────────────────────────────────────────────────────

const ToolBlock = struct {
    index: u64,
    id: []u8,
    name: []u8,
    input: std.ArrayList(u8) = .empty,
};

const ReasoningBlock = struct {
    index: u64,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    redacted: ?[]u8 = null,
};

const BedrockStream = struct {
    allocator: std.mem.Allocator,
    request: *http.Client.Request,
    response: http.Client.Response,
    transfer_buf: [8192]u8 = undefined,
    reader: ?*std.Io.Reader = null,
    liveness: liveness_reader.LivenessReader = undefined,
    liveness_buf: [8192]u8 = undefined,
    abort: ?*const AbortSignal = null,
    abort_registry: ?*provider_mod.RequestAbortRegistry = null,
    id: log.RequestId,
    credential: ?model_error.SecretPrint,
    image_placeholder_ids: []const []const u8 = &.{},
    done: bool = false,
    last_stop: StopReason = .unknown,
    stop_reported: bool = false,
    tools: std.ArrayList(ToolBlock) = .empty,
    reasoning: std.ArrayList(ReasoningBlock) = .empty,
    /// A text or tool-use block has started: reasoning after it is not at the
    /// head of the message and is not handed on for replay (moving it there
    /// would reorder the model's blocks; dropping trailing ones is allowed).
    content_started: bool = false,
    /// A reasoning block was withheld; every later one is withheld too, so
    /// what is replayed is always a prefix of what the model produced.
    reasoning_cut: bool = false,
    context_window_numbers: error_class.ContextWindowNumbers = .{},
    queue: std.ArrayList(StreamEvent) = .empty,
    queue_pos: usize = 0,

    fn handle(self: *BedrockStream) StreamHandle {
        return .{
            .ctx = @ptrCast(self),
            .image_placeholder_ids = self.image_placeholder_ids,
            .nextFn = &hNext,
            .deinitFn = &hDeinit,
            .stopReasonFn = &hStop,
            .requestIdFn = &hRid,
            .contextWindowNumbersFn = &hContextWindowNumbers,
        };
    }
    fn hNext(ctx: *anyopaque) anyerror!?StreamEvent {
        return @as(*BedrockStream, @ptrCast(@alignCast(ctx))).next();
    }
    fn hDeinit(ctx: *anyopaque) void {
        const s: *BedrockStream = @ptrCast(@alignCast(ctx));
        const a = s.allocator;
        s.deinit();
        a.destroy(s);
    }
    fn hStop(ctx: *anyopaque) StopReason {
        return @as(*BedrockStream, @ptrCast(@alignCast(ctx))).last_stop;
    }
    fn hRid(ctx: *anyopaque) log.RequestId {
        return @as(*BedrockStream, @ptrCast(@alignCast(ctx))).id;
    }
    fn hContextWindowNumbers(ctx: *anyopaque) error_class.ContextWindowNumbers {
        return @as(*BedrockStream, @ptrCast(@alignCast(ctx))).context_window_numbers;
    }

    fn deinit(self: *BedrockStream) void {
        self.allocator.free(self.image_placeholder_ids);
        for (self.queue.items[self.queue_pos..]) |ev| freeEvent(self.allocator, ev);
        self.queue.deinit(self.allocator);
        for (self.tools.items) |*t| {
            self.allocator.free(t.id);
            self.allocator.free(t.name);
            t.input.deinit(self.allocator);
        }
        self.tools.deinit(self.allocator);
        for (self.reasoning.items) |*r| freeReasoningBlock(self.allocator, r);
        self.reasoning.deinit(self.allocator);
        if (self.abort_registry) |registry| registry.unregister(self.request);
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    fn stalledVerdict(self: *BedrockStream) ?provider_mod.RequestAbortRegistry.Stall {
        const registry = self.abort_registry orelse return null;
        return registry.stalled(self.request);
    }

    /// Queue an owned event; on failure the event is freed here, so no path
    /// holds bytes nobody owns.
    fn push(self: *BedrockStream, ev: StreamEvent) !void {
        self.queue.append(self.allocator, ev) catch |err| {
            freeEvent(self.allocator, ev);
            return err;
        };
    }

    fn pushCopy(self: *BedrockStream, comptime tag: std.meta.Tag(StreamEvent), bytes: []const u8) !void {
        const owned = try self.allocator.dupe(u8, bytes);
        try self.push(@unionInit(StreamEvent, @tagName(tag), owned));
    }

    fn next(self: *BedrockStream) anyerror!?StreamEvent {
        while (true) {
            if (self.queue_pos < self.queue.items.len) {
                const ev = self.queue.items[self.queue_pos];
                self.queue_pos += 1;
                if (self.queue_pos == self.queue.items.len) {
                    self.queue.clearRetainingCapacity();
                    self.queue_pos = 0;
                }
                return ev;
            }
            if (self.done) return null;
            if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
            if (self.reader == null) {
                const raw = self.response.reader(&self.transfer_buf);
                self.reader = if (self.abort_registry) |registry| blk: {
                    self.liveness = liveness_reader.LivenessReader.init(raw, registry, self.request, &self.liveness_buf, .transport_only);
                    break :blk &self.liveness.interface;
                } else raw;
            }
            const frame = event_stream.readFrame(self.reader.?, self.allocator) catch |err| {
                self.done = true;
                if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
                if (self.stalledVerdict()) |stall| {
                    client_mod.reportBodyStall("bedrock", self.id, stall);
                    return error.StreamStalled;
                }
                // The connection closed inside a frame: the same failure as a
                // stream that ends before its stop event, and retried the same way.
                if (err == error.TruncatedFrame) {
                    client_mod.reportStreamIncomplete("bedrock", self.id);
                    return error.StreamIncomplete;
                }
                log.warnId("bedrock", self.id, "event stream read failed: {s}", .{@errorName(err)});
                return api_stream.midStreamReadError(err);
            } orelse {
                self.done = true;
                if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
                if (self.stalledVerdict()) |stall| {
                    client_mod.reportBodyStall("bedrock", self.id, stall);
                    return error.StreamStalled;
                }
                if (!self.stop_reported) {
                    client_mod.reportStreamIncomplete("bedrock", self.id);
                    return error.StreamIncomplete;
                }
                // Blocks the server never closed with contentBlockStop.
                while (self.reasoning.items.len > 0) try self.finishReasoning(0);
                continue; // drain anything queued, then null
            };
            defer self.allocator.free(frame);
            if (self.abort_registry) |registry| registry.touch(self.request);
            try self.handleFrame(frame);
        }
    }

    fn handleFrame(self: *BedrockStream, frame: []const u8) !void {
        var headers: [event_stream.MAX_HEADERS]event_stream.Header = undefined;
        const message = try event_stream.decode(frame, &headers);
        const message_type = message.header(":message-type") orelse "event";
        if (!std.mem.eql(u8, message_type, "event")) {
            self.done = true;
            return self.exceptionFailure(message);
        }
        const event_type = message.header(":event-type") orelse return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message.payload, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const payload = parsed.value.object;

        if (std.mem.eql(u8, event_type, "contentBlockStart")) {
            const index = intField(payload, "contentBlockIndex");
            const start = objectField(payload, "start") orelse return;
            const tool = objectField(start, "toolUse") orelse return;
            const id = stringField(tool, "toolUseId") orelse return;
            const name = stringField(tool, "name") orelse return;
            self.content_started = true;
            try self.tools.ensureUnusedCapacity(self.allocator, 1);
            const id_owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_owned);
            const name_owned = try self.allocator.dupe(u8, name);
            self.tools.appendAssumeCapacity(.{ .index = index, .id = id_owned, .name = name_owned });
        } else if (std.mem.eql(u8, event_type, "contentBlockDelta")) {
            const index = intField(payload, "contentBlockIndex");
            const delta = objectField(payload, "delta") orelse return;
            if (stringField(delta, "text")) |text| {
                self.content_started = true;
                if (text.len > 0) try self.pushCopy(.text, text);
            } else if (objectField(delta, "toolUse")) |tool| {
                const fragment = stringField(tool, "input") orelse return;
                for (self.tools.items) |*t| if (t.index == index) {
                    try t.input.appendSlice(self.allocator, fragment);
                    break;
                };
            } else if (objectField(delta, "reasoningContent")) |reasoning| {
                const block = try self.reasoningBlock(index);
                if (stringField(reasoning, "text")) |text| {
                    try block.text.appendSlice(self.allocator, text);
                    if (text.len > 0) try self.pushCopy(.thinking, text);
                }
                if (stringField(reasoning, "signature")) |signature| try block.signature.appendSlice(self.allocator, signature);
                if (stringField(reasoning, "redactedContent")) |redacted| {
                    // Copy first: a failed copy leaves the old bytes owned once.
                    const owned = try self.allocator.dupe(u8, redacted);
                    if (block.redacted) |old| self.allocator.free(old);
                    block.redacted = owned;
                }
            }
        } else if (std.mem.eql(u8, event_type, "contentBlockStop")) {
            const index = intField(payload, "contentBlockIndex");
            for (self.reasoning.items, 0..) |r, i| if (r.index == index) {
                try self.finishReasoning(i);
                return;
            };
            for (self.tools.items, 0..) |*t, i| if (t.index == index) {
                try self.queue.ensureUnusedCapacity(self.allocator, 1);
                const input = if (t.input.items.len == 0) try self.allocator.dupe(u8, "{}") else try t.input.toOwnedSlice(self.allocator);
                // From here the event owns id, name and input.
                self.queue.appendAssumeCapacity(.{ .tool_use_start = .{ .id = t.id, .name = t.name, .input_json = input } });
                t.input.deinit(self.allocator);
                _ = self.tools.orderedRemove(i);
                break;
            };
        } else if (std.mem.eql(u8, event_type, "messageStop")) {
            self.stop_reported = true;
            self.last_stop = mapStopReason(stringField(payload, "stopReason") orelse "");
        } else if (std.mem.eql(u8, event_type, "metadata")) {
            const usage = objectField(payload, "usage") orelse return;
            try self.queue.append(self.allocator, .{ .usage = .{
                .input_tokens = intField(usage, "inputTokens"),
                .output_tokens = intField(usage, "outputTokens"),
                .cache_read_input_tokens = intField(usage, "cacheReadInputTokens"),
                .cache_creation_input_tokens = intField(usage, "cacheWriteInputTokens"),
            } });
        }
    }

    fn reasoningBlock(self: *BedrockStream, index: u64) !*ReasoningBlock {
        for (self.reasoning.items) |*r| if (r.index == index) return r;
        // Reasoning that starts after the answer did is not at the head of
        // the message: it, and everything after it, stays out of the replay.
        if (self.content_started and !self.reasoning_cut) {
            self.reasoning_cut = true;
            log.warnId("bedrock", self.id, "reasoning block {d} follows text or a tool call: not replayed", .{index});
        }
        try self.reasoning.append(self.allocator, .{ .index = index });
        return &self.reasoning.items[self.reasoning.items.len - 1];
    }

    /// A reasoning block is complete: hand it on as a `reasoning_item` — its
    /// Converse request form, verbatim — when it is signed (or redacted) and
    /// still at the head of the message; drop it otherwise.
    fn finishReasoning(self: *BedrockStream, i: usize) !void {
        var block = self.reasoning.orderedRemove(i);
        defer freeReasoningBlock(self.allocator, &block);
        if (self.reasoning_cut) return;
        if (block.redacted == null and block.signature.items.len == 0) return; // unsigned reasoning is not replayable
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, REASONING_ITEM_PREFIX);
        if (block.redacted) |redacted| {
            try json.appendSlice(self.allocator, "{\"redactedContent\":");
            try util_json.serializeString(redacted, &json, self.allocator);
            try json.appendSlice(self.allocator, "}}");
        } else {
            try json.appendSlice(self.allocator, "{\"reasoningText\":{\"text\":");
            try util_json.serializeString(block.text.items, &json, self.allocator);
            try json.appendSlice(self.allocator, ",\"signature\":");
            try util_json.serializeString(block.signature.items, &json, self.allocator);
            try json.appendSlice(self.allocator, "}}}");
        }
        try self.push(.{ .reasoning_item = try json.toOwnedSlice(self.allocator) });
    }

    /// An exception (or error) frame ends the stream with what it says, in
    /// the shape `model_error` reads: `{"type":<exception type>,"message":…}`.
    /// The type names the category (throttling, unavailable, validation, …;
    /// `model_error.technicalCategory`); an overflow is ContextWindowExceeded.
    fn exceptionFailure(self: *BedrockStream, message: event_stream.Message) anyerror {
        const kind = message.header(":exception-type") orelse message.header(":error-code") orelse "exception";
        var parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, self.allocator, message.payload, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        // AWS documents the exception members (ConverseStreamOutput) without
        // their payload; the AWS SDKs read `message`. `:message-type error`
        // frames carry it in the `:error-message` header instead.
        const text: ?[]const u8 = blk: {
            if (parsed) |p| if (p.value == .object) {
                if (stringField(p.value.object, "message") orelse stringField(p.value.object, "Message")) |m| break :blk m;
            };
            if (message.header(":error-message")) |m| break :blk m;
            if (message.payload.len > 0 and std.unicode.utf8ValidateSlice(message.payload))
                break :blk message.payload[0..@min(message.payload.len, 2048)];
            break :blk null;
        };
        var shown: std.ArrayList(u8) = .empty;
        defer shown.deinit(self.allocator);
        const written = blk: {
            shown.appendSlice(self.allocator, "{\"type\":") catch break :blk false;
            util_json.serializeString(kind, &shown, self.allocator) catch break :blk false;
            if (text) |m| {
                shown.appendSlice(self.allocator, ",\"message\":") catch break :blk false;
                util_json.serializeString(m, &shown, self.allocator) catch break :blk false;
            }
            shown.append(self.allocator, '}') catch break :blk false;
            break :blk true;
        };
        client_mod.reportServerError("bedrock", self.id, if (written) shown.items else "{\"type\":\"exception\"}", self.credential);
        // AWS documents an overflow only as "a validation error"; the wording
        // the shared classifier knows (Anthropic's "prompt is too long", …)
        // is what decides here.
        if (text) |m| if (error_class.isContextWindowExceeded(m)) {
            self.context_window_numbers = error_class.parseContextWindowNumbers(m);
            return error.ContextWindowExceeded;
        };
        return error.ApiError;
    }
};

fn freeReasoningBlock(allocator: std.mem.Allocator, r: *ReasoningBlock) void {
    r.text.deinit(allocator);
    r.signature.deinit(allocator);
    if (r.redacted) |bytes| allocator.free(bytes);
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn intField(object: std.json.ObjectMap, name: []const u8) u64 {
    const value = object.get(name) orelse return 0;
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else 0;
}

/// Converse stop reasons. A guardrail or content filter stopped the answer on
/// purpose: that is a refusal, not a truncation.
pub fn mapStopReason(reason: []const u8) StopReason {
    const table = [_]struct { []const u8, StopReason }{
        .{ "end_turn", .end_turn },
        .{ "tool_use", .tool_use },
        .{ "max_tokens", .max_tokens },
        .{ "stop_sequence", .stop_sequence },
        .{ "guardrail_intervened", .refusal },
        .{ "content_filtered", .refusal },
        .{ "model_context_window_exceeded", .max_tokens },
    };
    for (table) |row| if (std.mem.eql(u8, reason, row[0])) return row[1];
    return .unknown;
}

fn freeEvent(allocator: std.mem.Allocator, ev: StreamEvent) void {
    switch (ev) {
        .text, .thinking, .reasoning_item => |bytes| allocator.free(bytes),
        .tool_use_start => |tu| {
            allocator.free(tu.id);
            allocator.free(tu.name);
            allocator.free(tu.input_json);
        },
        else => {},
    }
}

fn shutdownRequest(raw: *anyopaque) void {
    const request: *http.Client.Request = @ptrCast(@alignCast(raw));
    provider_mod.abortHttpRequest(request);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testRequest(model: []const u8, messages: []const types.ApiMessage, tools: ?[]const json_mod.ToolDefinition, overrides: request_overrides.RequestOverrides) ConverseRequest {
    return .{
        .model = model,
        .messages = messages,
        .system = "be brief",
        .tools = tools,
        .overrides = overrides,
        .max_tokens = 32000,
        .dialect = dialect_mod.dialectForVendor(.bedrock, null, model),
    };
}

fn testBody(a: std.mem.Allocator, req: ConverseRequest) ![]u8 {
    var report = json_mod.SerializationReport{};
    defer report.deinit(a);
    const body = try serializeConverseRequest(a, req, &report);
    errdefer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    parsed.deinit();
    return body;
}

fn has(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

test "Converse URL percent-encodes the model id" {
    const a = testing.allocator;
    const url = try converseStreamUrl(a, "https://bedrock-runtime.us-east-1.amazonaws.com/", "anthropic.claude-haiku-4-5-20251001-v1:0");
    defer a.free(url);
    try testing.expectEqualStrings("https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-haiku-4-5-20251001-v1%3A0/converse-stream", url);
    const arn = try converseStreamUrl(a, "https://x", "arn:aws:bedrock:us-east-1:1:inference-profile/us.a.b");
    defer a.free(arn);
    try testing.expect(std.mem.indexOf(u8, arn, "%2Fus.a.b") != null);
}

test "Converse body: messages, system with a cache point, tools, thinking fields" {
    const a = testing.allocator;
    const messages = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "list files" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .thinking = "unsigned, never replayed" },
            .{ .text = "" },
            .{ .tool_use = .{ .id = "tu_1", .name = "Glob", .input = "{\"pattern\":\"*\"}" } },
        } },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = "a.txt", .is_error = true } }} },
    };
    const tools = [_]json_mod.ToolDefinition{.{ .name = "Glob", .description = "find files", .input_schema = .{} }};
    var report = json_mod.SerializationReport{};
    defer report.deinit(a);
    const body = try serializeConverseRequest(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, &tools, .{ .reasoning_effort = .high, .tool_choice = .{ .type = "auto" } }), &report);
    defer a.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":[{\"text\":\"list files\"}]}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"toolUse\":{\"toolUseId\":\"tu_1\",\"name\":\"Glob\",\"input\":{\"pattern\":\"*\"}}}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"toolResult\":{\"toolUseId\":\"tu_1\",\"content\":[{\"text\":\"a.txt\"}],\"status\":\"error\"}}") != null);
    // The conversation's cache point closes the last message.
    try testing.expect(std.mem.indexOf(u8, body, "\"status\":\"error\"}},{\"cachePoint\":{\"type\":\"default\"}}]}]") != null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "cachePoint"));
    try testing.expect(std.mem.indexOf(u8, body, "unsigned, never replayed") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"text\":\"be brief\"},{\"cachePoint\":{\"type\":\"default\"}}]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"inferenceConfig\":{\"maxTokens\":32000}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"cachePoint\":{\"type\":\"default\"}}],\"toolChoice\":{\"auto\":{}}}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"additionalModelRequestFields\":{\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}}") != null);
}

test "Converse body: no cache points and no fields for a vendor without them" {
    const a = testing.allocator;
    const messages = [_]types.ApiMessage{.{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} }};
    var report = json_mod.SerializationReport{};
    defer report.deinit(a);
    const body = try serializeConverseRequest(a, testRequest("deepseek.v3-v1:0", &messages, null, .{ .reasoning_effort = .high }), &report);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "cachePoint") == null);
    try testing.expect(std.mem.indexOf(u8, body, "additionalModelRequestFields") == null);
}

test "Converse body: signed reasoning in the conversation goes back verbatim, this model's and this wire's only" {
    const a = testing.allocator;
    const signed = "{\"reasoningContent\":{\"reasoningText\":{\"text\":\"t\",\"signature\":\"sig\"}}}";
    const messages = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
        .{
            .role = .assistant,
            .content = &[_]types.ApiContent{
                .{ .reasoning_item = .{ .model = "us.anthropic.claude-sonnet-4-6", .json = signed } },
                // Another model's signature, and another wire's item: never sent.
                .{ .reasoning_item = .{ .model = "us.anthropic.claude-opus-4-6-v1", .json = "{\"reasoningContent\":{\"redactedContent\":\"b3RoZXI=\"}}" } },
                .{ .reasoning_item = .{ .model = "us.anthropic.claude-sonnet-4-6", .json = "{\"type\":\"reasoning\",\"encrypted_content\":\"x\"}" } },
                .{ .thinking = "t" },
                .{ .tool_use = .{ .id = "tu_1", .name = "Glob", .input = "{}" } },
            },
        },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = "x", .is_error = false } }} },
    };
    const body = try testBody(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, null, .{}));
    defer a.free(body);
    try testing.expect(has(body, "{\"role\":\"assistant\",\"content\":[" ++ signed ++ ",{\"toolUse\":"));
    try testing.expect(!has(body, "b3RoZXI="));
    try testing.expect(!has(body, "encrypted_content"));
}

test "Converse body: adjacent messages of one role become one" {
    const a = testing.allocator;
    const messages = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "first" }} },
        // Nothing this wire sends: dropped, leaving two user messages in a row.
        .{ .role = .assistant, .content = &[_]types.ApiContent{.{ .text = "" }} },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "second" }} },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "" }} },
    };
    const body = try testBody(a, testRequest("deepseek.v3-v1:0", &messages, null, .{}));
    defer a.free(body);
    try testing.expect(has(body, "{\"messages\":[{\"role\":\"user\",\"content\":[{\"text\":\"first\"},{\"text\":\"second\"}]}]"));

    // With a cache point the merged message still closes with it.
    const claude = try testBody(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, null, .{}));
    defer a.free(claude);
    try testing.expect(has(claude, "{\"messages\":[{\"role\":\"user\",\"content\":[{\"text\":\"first\"},{\"text\":\"second\"},{\"cachePoint\":{\"type\":\"default\"}}]}]"));
}

test "Converse body: sampling and a forced tool go out unless the model always thinks" {
    const a = testing.allocator;
    const messages = [_]types.ApiMessage{.{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} }};
    const tools = [_]json_mod.ToolDefinition{.{ .name = "Glob", .description = "find files", .input_schema = .{} }};
    const overrides: request_overrides.RequestOverrides = .{ .reasoning_effort = .high, .temperature = 0.25, .top_p = 0.5, .tool_choice = .{ .type = "tool", .name = "Glob" } };

    // Sonnet 4.6: thinking is off when omitted, so the caller's members win.
    const sonnet = try testBody(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, &tools, overrides));
    defer a.free(sonnet);
    try testing.expect(has(sonnet, "\"inferenceConfig\":{\"maxTokens\":32000,\"temperature\":0.25,\"topP\":0.5}"));
    try testing.expect(has(sonnet, "\"toolChoice\":{\"tool\":{\"name\":\"Glob\"}}"));
    try testing.expect(!has(sonnet, "additionalModelRequestFields"));

    // Opus 5.5 always thinks: the conflicting members stay home.
    const opus = try testBody(a, testRequest("us.anthropic.claude-opus-5-5", &messages, &tools, overrides));
    defer a.free(opus);
    try testing.expect(has(opus, "\"inferenceConfig\":{\"maxTokens\":32000}"));
    try testing.expect(!has(opus, "toolChoice"));
    try testing.expect(has(opus, "\"additionalModelRequestFields\":{\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}}"));

    // A vendor without thinking fields sends both untouched.
    const deepseek = try testBody(a, testRequest("deepseek.v3-v1:0", &messages, &tools, overrides));
    defer a.free(deepseek);
    try testing.expect(has(deepseek, "\"temperature\":0.25,\"topP\":0.5}"));
    try testing.expect(has(deepseek, "\"toolChoice\":{\"tool\":{\"name\":\"Glob\"}}"));
}

test "Converse body: a non-vision tool image becomes a placeholder and is reported" {
    const a = testing.allocator;
    const image = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}";
    const messages = [_]types.ApiMessage{
        .{ .role = .assistant, .content = &[_]types.ApiContent{.{ .tool_use = .{ .id = "r1", .name = "Read", .input = "{}" } }} },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "r1", .content = image, .is_error = false } }} },
    };
    var report = json_mod.SerializationReport{};
    defer report.deinit(a);
    const body = try serializeConverseRequest(a, testRequest("deepseek.v3-v1:0", &messages, null, .{}), &report);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "QUJD") == null);
    try testing.expectEqual(@as(usize, 1), report.placeholder_ids.items.len);

    var vision_report = json_mod.SerializationReport{};
    defer vision_report.deinit(a);
    const vision = try serializeConverseRequest(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, null, .{}), &vision_report);
    defer a.free(vision);
    try testing.expect(std.mem.indexOf(u8, vision, "{\"image\":{\"format\":\"png\",\"source\":{\"bytes\":\"QUJD\"}}}") != null);
}

test "Converse stop reasons map onto the neutral set" {
    try testing.expectEqual(StopReason.tool_use, mapStopReason("tool_use"));
    try testing.expectEqual(StopReason.refusal, mapStopReason("guardrail_intervened"));
    try testing.expectEqual(StopReason.max_tokens, mapStopReason("model_context_window_exceeded"));
    try testing.expectEqual(StopReason.unknown, mapStopReason("something_new"));
}
