//! Amazon Bedrock model catalog → offers, the way OpenRouter's is.
//!
//! Two documents, parsed separately and kept separate, like OpenRouter's
//! models and endpoints:
//!
//! - **Foundation models** (`GET https://bedrock.<region>.amazonaws.com/foundation-models`,
//!   ListFoundationModels) describe what the region hosts: id, provider,
//!   modalities, streaming, inference types, lifecycle.
//! - **Inference profiles** (`GET https://bedrock.<region>.amazonaws.com/inference-profiles?type=SYSTEM_DEFINED&maxResults=1000`,
//!   ListInferenceProfiles) are the cross-region routes (`us.…`, `eu.…`,
//!   `global.…`) — the only way to invoke many newer models on demand.
//!
//! Every usable entry becomes one model on the region's channel, so
//! `anthropic.claude-x` (in-region) and `us.anthropic.claude-x` (cross-region)
//! stay two offers: a different route, different quotas, different data
//! residency. Each declares its dialect from the catalog's `providerName`
//! (`Anthropic` → `.claude`, …), never from a name guess; a provider with no
//! dialect here declares none and keeps the plain Converse dialect.
//!
//! Like `openrouter.zig`, this is parsing only: no I/O. The host reads the
//! documents (from files today) and hands the bytes in. Integration notes for
//! the wire are the header of `src/api/dialects/bedrock.zig`.

const std = @import("std");
const ids = @import("ids.zig");
const offer_mod = @import("offer.zig");
const profile_mod = @import("profile.zig");

const Slug = ids.Slug;
const Vendor = profile_mod.Vendor;

pub const AdapterError = error{ OutOfMemory, InvalidDocument, InvalidSlug, NoUsableModels };

/// The catalog's `providerName` → the dialect its models speak.
pub fn vendorForProvider(provider_name: []const u8) ?Vendor {
    const table = [_]struct { []const u8, Vendor }{
        .{ "Anthropic", .claude },
        .{ "DeepSeek", .deepseek },
        .{ "Qwen", .qwen },
        .{ "Moonshot AI", .kimi },
        .{ "MiniMax", .minimax },
        .{ "Mistral AI", .mistral },
        .{ "OpenAI", .openai },
        .{ "Z.AI", .glm },
    };
    for (table) |row| if (std.ascii.eqlIgnoreCase(provider_name, row[0])) return row[1];
    return null;
}

pub const FoundationModel = struct {
    model_id: []const u8,
    model_arn: []const u8,
    name: []const u8,
    provider_name: []const u8,
    image_input: bool,
    text_output: bool,
    streaming: bool,
    on_demand: bool,
    active: bool,
};

pub const InferenceProfile = struct {
    id: []const u8,
    name: []const u8,
    active: bool,
    /// ARNs of the foundation models it routes to.
    model_arns: []const []const u8,
};

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn listContains(value: ?std.json.Value, wanted: []const u8) bool {
    const v = value orelse return false;
    if (v != .array) return false;
    for (v.array.items) |item| {
        if (item == .string and std.ascii.eqlIgnoreCase(item.string, wanted)) return true;
    }
    return false;
}

/// Parse a ListFoundationModels response. Strings are copied into `arena`.
pub fn parseFoundationModels(arena: std.mem.Allocator, json: []const u8) AdapterError![]FoundationModel {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;
    const list = root.object.get("modelSummaries") orelse return error.InvalidDocument;
    if (list != .array) return error.InvalidDocument;
    var out: std.ArrayList(FoundationModel) = .empty;
    for (list.array.items) |item| {
        if (item != .object) return error.InvalidDocument;
        const o = item.object;
        const model_id = stringOf(o.get("modelId")) orelse return error.InvalidDocument;
        const lifecycle = o.get("modelLifecycle");
        const status = if (lifecycle) |l| (if (l == .object) stringOf(l.object.get("status")) else null) else null;
        try out.append(arena, .{
            .model_id = model_id,
            .model_arn = stringOf(o.get("modelArn")) orelse "",
            .name = stringOf(o.get("modelName")) orelse model_id,
            .provider_name = stringOf(o.get("providerName")) orelse "",
            .image_input = listContains(o.get("inputModalities"), "IMAGE"),
            .text_output = listContains(o.get("outputModalities"), "TEXT"),
            .streaming = if (o.get("responseStreamingSupported")) |v| v == .bool and v.bool else false,
            .on_demand = listContains(o.get("inferenceTypesSupported"), "ON_DEMAND"),
            // A missing lifecycle reads as active; LEGACY still serves but is
            // on its way out, and is kept.
            .active = status == null or !std.ascii.eqlIgnoreCase(status.?, "EOL"),
        });
    }
    return out.toOwnedSlice(arena);
}

/// Parse a ListInferenceProfiles response.
pub fn parseInferenceProfiles(arena: std.mem.Allocator, json: []const u8) AdapterError![]InferenceProfile {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;
    const list = root.object.get("inferenceProfileSummaries") orelse return error.InvalidDocument;
    if (list != .array) return error.InvalidDocument;
    var out: std.ArrayList(InferenceProfile) = .empty;
    for (list.array.items) |item| {
        if (item != .object) return error.InvalidDocument;
        const o = item.object;
        const id = stringOf(o.get("inferenceProfileId")) orelse return error.InvalidDocument;
        var arns: std.ArrayList([]const u8) = .empty;
        if (o.get("models")) |models| {
            if (models != .array) return error.InvalidDocument;
            for (models.array.items) |m| {
                if (m != .object) continue;
                if (stringOf(m.object.get("modelArn"))) |arn| try arns.append(arena, arn);
            }
        }
        try out.append(arena, .{
            .id = id,
            .name = stringOf(o.get("inferenceProfileName")) orelse id,
            .active = if (stringOf(o.get("status"))) |s| std.ascii.eqlIgnoreCase(s, "ACTIVE") else true,
            .model_arns = try arns.toOwnedSlice(arena),
        });
    }
    return out.toOwnedSlice(arena);
}

/// The foundation model an ARN names (`…:foundation-model/<modelId>`).
fn modelIdOfArn(arn: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, arn, '/') orelse return arn;
    return arn[slash + 1 ..];
}

fn findModel(models: []const FoundationModel, model_id: []const u8) ?*const FoundationModel {
    for (models) |*m| if (std.mem.eql(u8, m.model_id, model_id)) return m;
    return null;
}

fn capabilities(base: FoundationModel) offer_mod.CapabilityMatrix {
    return (offer_mod.CapabilityMatrix{
        .provenance = offer_mod.Provenance.known(.provider_catalog, null),
    })
        .with(.streaming, .supported)
        .with(.vision, if (base.image_input) .supported else .unsupported);
}

const ROUTES = [_]profile_mod.ProtocolRoute{.{ .protocol = .bedrock_converse }};

/// Build the region's channel from the two documents. Usable = text output,
/// streaming, active; a foundation model must also be invocable on demand,
/// an inference profile must route to a model the region lists.
pub fn buildChannel(
    arena: std.mem.Allocator,
    region: []const u8,
    models: []const FoundationModel,
    profiles: []const InferenceProfile,
) AdapterError!profile_mod.ChannelDescriptor {
    var entries: std.ArrayList(profile_mod.ModelEntry) = .empty;
    for (models) |m| {
        if (!m.text_output or !m.streaming or !m.active or !m.on_demand) continue;
        try entries.append(arena, .{
            .request_model_id = m.model_id,
            .display_name = m.name,
            .canonical_model_id = m.model_id,
            .upstream_model_id = m.model_id,
            .capabilities = capabilities(m),
            .dialect = vendorForProvider(m.provider_name),
        });
    }
    for (profiles) |p| {
        if (!p.active or p.model_arns.len == 0) continue;
        const base = findModel(models, modelIdOfArn(p.model_arns[0])) orelse continue;
        if (!base.text_output or !base.streaming) continue;
        try entries.append(arena, .{
            .request_model_id = p.id,
            .display_name = p.name,
            .canonical_model_id = base.model_id,
            .upstream_model_id = base.model_id,
            .capabilities = capabilities(base.*),
            .dialect = vendorForProvider(base.provider_name),
        });
    }
    if (entries.items.len == 0) return error.NoUsableModels;
    const id = Slug.parse(region) catch return error.InvalidSlug;
    const base_url = std.fmt.allocPrint(arena, "https://bedrock-runtime.{s}.amazonaws.com", .{region}) catch return error.OutOfMemory;
    const display = std.fmt.allocPrint(arena, "Bedrock · {s}", .{region}) catch return error.OutOfMemory;
    return .{
        .id = id,
        .display_name = display,
        .base_url = base_url,
        .routes = &ROUTES,
        .region = try arena.dupe(u8, region),
        .models = try entries.toOwnedSlice(arena),
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

pub const SAMPLE_FOUNDATION_MODELS =
    \\{"modelSummaries":[
    \\ {"modelId":"anthropic.claude-sonnet-4-6","modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
    \\  "modelName":"Claude Sonnet 4.6","providerName":"Anthropic","inputModalities":["TEXT","IMAGE"],"outputModalities":["TEXT"],
    \\  "responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},
    \\ {"modelId":"deepseek.v3-v1:0","modelArn":"arn:aws:bedrock:us-east-1::foundation-model/deepseek.v3-v1:0",
    \\  "modelName":"DeepSeek-V3.1","providerName":"DeepSeek","inputModalities":["TEXT"],"outputModalities":["TEXT"],
    \\  "responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},
    \\ {"modelId":"amazon.titan-embed-text-v2:0","modelName":"Titan Embeddings","providerName":"Amazon","inputModalities":["TEXT"],
    \\  "outputModalities":["EMBEDDING"],"responseStreamingSupported":false,"inferenceTypesSupported":["ON_DEMAND"]},
    \\ {"modelId":"amazon.nova-pro-v1:0","modelName":"Nova Pro","providerName":"Amazon","inputModalities":["TEXT","IMAGE"],
    \\  "outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"LEGACY"}}
    \\]}
;

pub const SAMPLE_INFERENCE_PROFILES =
    \\{"inferenceProfileSummaries":[
    \\ {"inferenceProfileId":"us.anthropic.claude-sonnet-4-6","inferenceProfileName":"US Claude Sonnet 4.6","status":"ACTIVE","type":"SYSTEM_DEFINED",
    \\  "models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6"},
    \\            {"modelArn":"arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6"}]},
    \\ {"inferenceProfileId":"us.vendor.unknown-model","inferenceProfileName":"Unlisted","status":"ACTIVE","type":"SYSTEM_DEFINED",
    \\  "models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/vendor.unknown-model"}]}
    \\]}
;

test "foundation models and inference profiles become offers on the region's channel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const models = try parseFoundationModels(arena, SAMPLE_FOUNDATION_MODELS);
    const profiles = try parseInferenceProfiles(arena, SAMPLE_INFERENCE_PROFILES);
    const channel = try buildChannel(arena, "us-east-1", models, profiles);

    try testing.expectEqualStrings("https://bedrock-runtime.us-east-1.amazonaws.com", channel.base_url);
    try testing.expectEqual(profile_mod.Protocol.bedrock_converse, channel.routes[0].protocol);
    // DeepSeek on demand, Nova on demand (legacy still serves), and the Claude
    // profile. Not: the embedding model, Claude in-region (profile-only), the
    // profile whose model the region does not list.
    try testing.expectEqual(@as(usize, 3), channel.models.len);
    try testing.expectEqualStrings("deepseek.v3-v1:0", channel.models[0].request_model_id);
    try testing.expectEqual(Vendor.deepseek, channel.models[0].dialect.?);
    try testing.expectEqual(offer_mod.Tri.unsupported, channel.models[0].capabilities.get(.vision));
    try testing.expectEqualStrings("amazon.nova-pro-v1:0", channel.models[1].request_model_id);
    try testing.expect(channel.models[1].dialect == null);
    try testing.expectEqualStrings("us.anthropic.claude-sonnet-4-6", channel.models[2].request_model_id);
    try testing.expectEqualStrings("anthropic.claude-sonnet-4-6", channel.models[2].canonical_model_id.?);
    try testing.expectEqual(Vendor.claude, channel.models[2].dialect.?);
    try testing.expectEqual(offer_mod.Tri.supported, channel.models[2].capabilities.get(.vision));
}

test "a malformed document is an error, an empty one has no usable models" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidDocument, parseFoundationModels(arena, "{\"models\":[]}"));
    try testing.expectError(error.InvalidDocument, parseFoundationModels(arena, "{\"modelSummaries\":[{\"modelName\":\"no id\"}]}"));
    try testing.expectError(error.InvalidDocument, parseInferenceProfiles(arena, "[]"));
    const none = try parseFoundationModels(arena, "{\"modelSummaries\":[]}");
    try testing.expectError(error.NoUsableModels, buildChannel(arena, "us-east-1", none, &.{}));
    try testing.expectError(error.InvalidSlug, buildChannel(arena, "US EAST", try parseFoundationModels(arena, SAMPLE_FOUNDATION_MODELS), &.{}));
}

test "providerName maps to a dialect; unknown providers declare none" {
    try testing.expectEqual(Vendor.claude, vendorForProvider("Anthropic").?);
    try testing.expectEqual(Vendor.kimi, vendorForProvider("Moonshot AI").?);
    try testing.expect(vendorForProvider("Meta") == null);
}
