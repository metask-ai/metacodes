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
//! reasoning blocks, signatures intact, while a tool loop is in progress. The
//! conversation keeps thinking text but not signatures, so this client keeps
//! them itself (`ReasoningStore`): the reasoning of a response is stored under
//! that response's first tool-use id and put back in front of the assistant
//! message carrying that id.

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
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const model_context_mod = @import("../app/model_context.zig");

const StreamEvent = api_stream.StreamEvent;
const StreamHandle = api_stream.StreamHandle;
const StopReason = api_stream.StopReason;
const UsageDelta = api_stream.UsageDelta;

pub const DEFAULT_BEDROCK_BASE = "https://bedrock-runtime.us-east-1.amazonaws.com";

/// Reasoning blocks of one response, as Converse request JSON
/// (`{"reasoningContent":{...}},...`), keyed by the response's first tool-use
/// id. Owned; bounded so a long session cannot grow it without limit.
pub const ReasoningStore = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    entries: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    /// Only the turn in progress needs its reasoning back; a handful covers
    /// parallel subagents sharing one client.
    pub const MAX_ENTRIES: usize = 64;

    pub fn init(allocator: std.mem.Allocator) ReasoningStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReasoningStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    /// Takes ownership of neither argument; copies both.
    pub fn put(self: *ReasoningStore, tool_use_id: []const u8, blocks_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.count() >= MAX_ENTRIES) {
            const oldest_key = self.entries.keys()[0];
            const oldest_value = self.entries.values()[0];
            self.entries.orderedRemoveAt(0);
            self.allocator.free(oldest_key);
            self.allocator.free(oldest_value);
        }
        const value = try self.allocator.dupe(u8, blocks_json);
        errdefer self.allocator.free(value);
        if (self.entries.getPtr(tool_use_id)) |existing| {
            self.allocator.free(existing.*);
            existing.* = value;
            return;
        }
        const key = try self.allocator.dupe(u8, tool_use_id);
        errdefer self.allocator.free(key);
        try self.entries.put(self.allocator, key, value);
    }

    /// Appends the stored blocks for `tool_use_id` (followed by a comma) to
    /// `out`; false when there are none.
    pub fn appendFor(self: *ReasoningStore, tool_use_id: []const u8, out: *std.ArrayList(u8), a: std.mem.Allocator) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const blocks = self.entries.get(tool_use_id) orelse return false;
        try out.appendSlice(a, blocks);
        try out.append(a, ',');
        return true;
    }
};

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
    /// The vendor the route declares for the hosted model; null reads it from
    /// the model id.
    dialect_vendor: ?dialect_mod.Vendor = null,
    catalog: ?catalog_mod.Catalog = null,
    host_capabilities: image_capability.Declarations = .{},
    reasoning: ReasoningStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, base_url: ?[]const u8) BedrockClient {
        return .{
            .allocator = allocator,
            .credential = .{ .fixed = api_key },
            .base_url = base_url orelse DEFAULT_BEDROCK_BASE,
            .model = model,
            .http_client = http.Client{ .allocator = allocator, .io = io },
            .stream_idle_timeout_ms = client_mod.streamIdleTimeoutMsFromEnv(),
            .stream_body_idle_timeout_ms = client_mod.streamBodyIdleTimeoutMsFromEnv(),
            .reasoning = ReasoningStore.init(allocator),
        };
    }

    pub fn deinit(self: *BedrockClient) void {
        self.abort_registry.deinit(self.allocator);
        self.reasoning.deinit();
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
            .declared = self.dialect_vendor,
            .reasoning = &self.reasoning,
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
        var dialect = self.dialect_resolver.resolve(.bedrock, self.dialect_vendor, model);
        const from_catalog: ?bool = if (self.catalog) |*catalog| catalog.imageInputFor(model) else null;
        dialect.declareImageInput(self.host_capabilities.imageInputFor(model), from_catalog);
        return dialect;
    }

    pub fn supportsForModel(self: *const BedrockClient, cap: provider_mod.Capability, model: []const u8) bool {
        return switch (cap) {
            .image_input => self.dialectFor(model).profileFor(.bedrock, model).supports_image_input,
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
            .reasoning_store = &self.reasoning,
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
    /// Reasoning to put back in front of assistant tool turns; null keeps none.
    reasoning: ?*ReasoningStore = null,
};

/// Neutral conversation → Converse request body. Caller frees.
pub fn serializeConverseRequest(allocator: std.mem.Allocator, req: ConverseRequest, report: *json_mod.SerializationReport) ![]u8 {
    const profile = req.dialect.profileFor(.bedrock, req.model);
    const cache_points = bedrock_dialect.supportsCachePoints(req.declared, req.model);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"messages\":[");
    var first_message = true;
    for (req.messages) |m| {
        const mark = out.items.len;
        if (!first_message) try out.append(allocator, ',');
        try out.appendSlice(allocator, if (m.role == .user) "{\"role\":\"user\",\"content\":[" else "{\"role\":\"assistant\",\"content\":[");
        const blocks_start = out.items.len;
        try serializeContent(allocator, &out, m, req, profile, report);
        if (out.items.len == blocks_start) {
            // Converse rejects a message with no blocks; such a message carried
            // only content this wire does not send (a lone thinking block).
            out.shrinkRetainingCapacity(mark);
            continue;
        }
        if (out.items[out.items.len - 1] == ',') out.items.len -= 1;
        try out.appendSlice(allocator, "]}");
        first_message = false;
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
        if (cache_points) try out.appendSlice(allocator, ",{\"cachePoint\":{\"type\":\"default\"}}");
        try out.append(allocator, ']');
    }

    try out.print(allocator, ",\"inferenceConfig\":{{\"maxTokens\":{d}", .{req.max_tokens});
    if (req.overrides.temperature) |t| {
        try out.appendSlice(allocator, ",\"temperature\":");
        try util_json.serializeNumber(t, &out, allocator);
    }
    if (req.overrides.top_p) |p| {
        try out.appendSlice(allocator, ",\"topP\":");
        try util_json.serializeNumber(p, &out, allocator);
    }
    try out.append(allocator, '}');

    if (req.tools) |tools| {
        var any = false;
        for (tools) |t| {
            if (t.server_type != null) continue; // Anthropic server tools have no Converse form
            try out.appendSlice(allocator, if (any) "," else ",\"toolConfig\":{\"tools\":[");
            any = true;
            try out.appendSlice(allocator, "{\"toolSpec\":{\"name\":");
            try util_json.serializeString(t.name, &out, allocator);
            try out.appendSlice(allocator, ",\"description\":");
            try util_json.serializeString(t.description, &out, allocator);
            try out.appendSlice(allocator, ",\"inputSchema\":{\"json\":");
            try @import("request.zig").serializeInputSchema(t.input_schema, &out, allocator);
            try out.appendSlice(allocator, "}}}");
        }
        if (any) {
            if (cache_points) try out.appendSlice(allocator, ",{\"cachePoint\":{\"type\":\"default\"}}");
            try out.append(allocator, ']');
            if (req.overrides.tool_choice) |tc| try serializeToolChoice(allocator, &out, tc);
            try out.append(allocator, '}');
        }
    }

    var additional: std.ArrayList(u8) = .empty;
    defer additional.deinit(allocator);
    try bedrock_dialect.serializeAdditionalFields(req.dialect, req.model, req.overrides.reasoning_effort, &additional, allocator);
    if (additional.items.len > 0) {
        try out.appendSlice(allocator, ",\"additionalModelRequestFields\":{");
        try out.appendSlice(allocator, additional.items);
        try out.append(allocator, '}');
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
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
    if (m.role == .assistant) if (req.reasoning) |store| {
        for (m.content) |c| switch (c) {
            .tool_use => |tu| {
                _ = try store.appendFor(tu.id, out, allocator);
                break;
            },
            else => {},
        };
    };
    for (m.content) |c| switch (c) {
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
        // Unsigned thinking cannot be replayed on Bedrock; the signed copy
        // comes from the reasoning store above.
        .thinking, .reasoning_item => {},
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
    reasoning_store: ?*ReasoningStore = null,
    done: bool = false,
    last_stop: StopReason = .unknown,
    stop_reported: bool = false,
    tools: std.ArrayList(ToolBlock) = .empty,
    reasoning: std.ArrayList(ReasoningBlock) = .empty,
    first_tool_id: ?[]u8 = null,
    queue: std.ArrayList(StreamEvent) = .empty,
    queue_pos: usize = 0,

    fn handle(self: *BedrockStream) StreamHandle {
        return .{ .ctx = @ptrCast(self), .image_placeholder_ids = self.image_placeholder_ids, .nextFn = &hNext, .deinitFn = &hDeinit, .stopReasonFn = &hStop, .requestIdFn = &hRid };
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
        self.freeReasoning();
        if (self.first_tool_id) |id| self.allocator.free(id);
        if (self.abort_registry) |registry| registry.unregister(self.request);
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    fn freeReasoning(self: *BedrockStream) void {
        for (self.reasoning.items) |*r| {
            r.text.deinit(self.allocator);
            r.signature.deinit(self.allocator);
            if (r.redacted) |bytes| self.allocator.free(bytes);
        }
        self.reasoning.deinit(self.allocator);
        self.reasoning = .empty;
    }

    fn stalledVerdict(self: *BedrockStream) ?provider_mod.RequestAbortRegistry.Stall {
        const registry = self.abort_registry orelse return null;
        return registry.stalled(self.request);
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
                try self.commitReasoning();
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
            const kind = message.header(":exception-type") orelse message.header(":error-code") orelse "exception";
            var buf: [1024]u8 = undefined;
            const shown = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"detail\":{s}}}", .{ kind, if (message.payload.len > 0 and message.payload.len < 900) message.payload else "null" }) catch kind;
            client_mod.reportServerError("bedrock", self.id, shown, self.credential);
            return error.ApiError;
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
            const id_owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_owned);
            const name_owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_owned);
            try self.tools.append(self.allocator, .{ .index = index, .id = id_owned, .name = name_owned });
            if (self.first_tool_id == null) self.first_tool_id = try self.allocator.dupe(u8, id);
        } else if (std.mem.eql(u8, event_type, "contentBlockDelta")) {
            const index = intField(payload, "contentBlockIndex");
            const delta = objectField(payload, "delta") orelse return;
            if (stringField(delta, "text")) |text| {
                if (text.len > 0) try self.queue.append(self.allocator, .{ .text = try self.allocator.dupe(u8, text) });
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
                    if (text.len > 0) try self.queue.append(self.allocator, .{ .thinking = try self.allocator.dupe(u8, text) });
                }
                if (stringField(reasoning, "signature")) |signature| try block.signature.appendSlice(self.allocator, signature);
                if (stringField(reasoning, "redactedContent")) |redacted| {
                    if (block.redacted) |old| self.allocator.free(old);
                    block.redacted = try self.allocator.dupe(u8, redacted);
                }
            }
        } else if (std.mem.eql(u8, event_type, "contentBlockStop")) {
            const index = intField(payload, "contentBlockIndex");
            for (self.tools.items, 0..) |*t, i| if (t.index == index) {
                const input = if (t.input.items.len == 0) try self.allocator.dupe(u8, "{}") else try t.input.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(input);
                try self.queue.append(self.allocator, .{ .tool_use_start = .{ .id = t.id, .name = t.name, .input_json = input } });
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
        try self.reasoning.append(self.allocator, .{ .index = index });
        return &self.reasoning.items[self.reasoning.items.len - 1];
    }

    /// File this response's reasoning under its first tool-use id, so the next
    /// request of the tool loop can put it back.
    fn commitReasoning(self: *BedrockStream) !void {
        defer self.freeReasoning();
        const store = self.reasoning_store orelse return;
        const tool_id = self.first_tool_id orelse return;
        var blocks: std.ArrayList(u8) = .empty;
        defer blocks.deinit(self.allocator);
        for (self.reasoning.items) |r| {
            if (r.redacted) |redacted| {
                if (blocks.items.len > 0) try blocks.append(self.allocator, ',');
                try blocks.appendSlice(self.allocator, "{\"reasoningContent\":{\"redactedContent\":");
                try util_json.serializeString(redacted, &blocks, self.allocator);
                try blocks.appendSlice(self.allocator, "}}");
                continue;
            }
            if (r.signature.items.len == 0) continue; // unsigned reasoning is not replayable
            if (blocks.items.len > 0) try blocks.append(self.allocator, ',');
            try blocks.appendSlice(self.allocator, "{\"reasoningContent\":{\"reasoningText\":{\"text\":");
            try util_json.serializeString(r.text.items, &blocks, self.allocator);
            try blocks.appendSlice(self.allocator, ",\"signature\":");
            try util_json.serializeString(r.signature.items, &blocks, self.allocator);
            try blocks.appendSlice(self.allocator, "}}}");
        }
        if (blocks.items.len > 0) try store.put(tool_id, blocks.items);
    }
};

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
        .text, .thinking => |bytes| allocator.free(bytes),
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

fn testRequest(model: []const u8, messages: []const types.ApiMessage, tools: ?[]const json_mod.ToolDefinition, overrides: request_overrides.RequestOverrides, store: ?*ReasoningStore) ConverseRequest {
    return .{
        .model = model,
        .messages = messages,
        .system = "be brief",
        .tools = tools,
        .overrides = overrides,
        .max_tokens = 32000,
        .dialect = dialect_mod.dialectForVendor(.bedrock, null, model),
        .reasoning = store,
    };
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
    const body = try serializeConverseRequest(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, &tools, .{ .reasoning_effort = .high, .tool_choice = .{ .type = "auto" } }, null), &report);
    defer a.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":[{\"text\":\"list files\"}]}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"toolUse\":{\"toolUseId\":\"tu_1\",\"name\":\"Glob\",\"input\":{\"pattern\":\"*\"}}}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"toolResult\":{\"toolUseId\":\"tu_1\",\"content\":[{\"text\":\"a.txt\"}],\"status\":\"error\"}}") != null);
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
    const body = try serializeConverseRequest(a, testRequest("deepseek.v3-v1:0", &messages, null, .{ .reasoning_effort = .high }, null), &report);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "cachePoint") == null);
    try testing.expect(std.mem.indexOf(u8, body, "additionalModelRequestFields") == null);
}

test "Converse body: stored signed reasoning goes back in front of its tool turn" {
    const a = testing.allocator;
    var store = ReasoningStore.init(a);
    defer store.deinit();
    try store.put("tu_1", "{\"reasoningContent\":{\"reasoningText\":{\"text\":\"t\",\"signature\":\"sig\"}}}");
    const messages = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{.{ .tool_use = .{ .id = "tu_1", .name = "Glob", .input = "{}" } }} },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = "x", .is_error = false } }} },
    };
    var report = json_mod.SerializationReport{};
    defer report.deinit(a);
    const body = try serializeConverseRequest(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, null, .{}, &store), &report);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{\"reasoningText\":{\"text\":\"t\",\"signature\":\"sig\"}}},{\"toolUse\":") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    parsed.deinit();
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
    const body = try serializeConverseRequest(a, testRequest("deepseek.v3-v1:0", &messages, null, .{}, null), &report);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "QUJD") == null);
    try testing.expectEqual(@as(usize, 1), report.placeholder_ids.items.len);

    var vision_report = json_mod.SerializationReport{};
    defer vision_report.deinit(a);
    const vision = try serializeConverseRequest(a, testRequest("us.anthropic.claude-sonnet-4-6", &messages, null, .{}, null), &vision_report);
    defer a.free(vision);
    try testing.expect(std.mem.indexOf(u8, vision, "{\"image\":{\"format\":\"png\",\"source\":{\"bytes\":\"QUJD\"}}}") != null);
}

test "Converse stop reasons map onto the neutral set" {
    try testing.expectEqual(StopReason.tool_use, mapStopReason("tool_use"));
    try testing.expectEqual(StopReason.refusal, mapStopReason("guardrail_intervened"));
    try testing.expectEqual(StopReason.max_tokens, mapStopReason("model_context_window_exceeded"));
    try testing.expectEqual(StopReason.unknown, mapStopReason("something_new"));
}

test "ReasoningStore keeps the newest entries within its bound" {
    const a = testing.allocator;
    var store = ReasoningStore.init(a);
    defer store.deinit();
    var buf: [16]u8 = undefined;
    for (0..ReasoningStore.MAX_ENTRIES + 3) |i| try store.put(try std.fmt.bufPrint(&buf, "id{d}", .{i}), "{}");
    try testing.expectEqual(ReasoningStore.MAX_ENTRIES, store.entries.count());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try testing.expect(!try store.appendFor("id0", &out, a));
    try testing.expect(try store.appendFor(try std.fmt.bufPrint(&buf, "id{d}", .{ReasoningStore.MAX_ENTRIES + 2}), &out, a));
}
