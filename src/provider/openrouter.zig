//! OpenRouter model/endpoint catalog and routing adapters (issue #16, P1).
//!
//! Three separate things, deliberately kept separate because the upstream API
//! keeps them separate and conflating them is how a UI ends up claiming a
//! context window or a price it never received:
//!
//! - **Models** (`GET /models`) describe a canonical model: name, context
//!   length, declared pricing, supported parameters.
//! - **Endpoints** (`GET /models/{author}/{slug}/endpoints`) describe the
//!   *routes* behind that model: one per upstream provider, each with its own
//!   context length, price, quantization, and status.
//! - **Provider preferences** are the caller's routing intent, which compiles
//!   into a `RoutePolicy` the kernel already knows how to enforce.
//!
//! A model that lists three endpoints is three offers. Merging them would
//! reproduce exactly the "a model name identifies the route" mistake the offer
//! model exists to correct.
//!
//! Everything here is parsing. No network I/O, no client: the host fetches the
//! bytes and hands them in, which is what keeps the provider subsystem free of
//! a transport dependency.
//!
//! Missing data stays missing. An endpoint with no pricing is `unknown`, not
//! free; with no context length it is `unknown`, not unlimited; with no status
//! its health is `unknown`, not healthy.

const std = @import("std");
const ids = @import("ids.zig");
const offer = @import("offer.zig");
const profile_mod = @import("profile.zig");
const selection_mod = @import("selection.zig");
const controls_mod = @import("controls.zig");

pub const Slug = ids.Slug;
pub const RoutePolicy = selection_mod.RoutePolicy;

pub const MAX_MODELS: usize = 512;
pub const MAX_ENDPOINTS: usize = 64;

pub const AdapterError = error{
    OutOfMemory,
    InvalidDocument,
    TooManyModels,
    TooManyEndpoints,
    /// A price field that is present but not a number in the documented
    /// "decimal string, USD per token" form. Coercing it to zero would produce
    /// a free-looking route.
    MalformedPrice,
    InvalidSlug,
    TooManyChannels,
    ControlTextTooLong,
};

// ── model catalog ────────────────────────────────────────────────────────────

/// One canonical model as `GET /models` describes it. Endpoint-level facts are
/// deliberately absent: they belong to `Endpoint`.
pub const CatalogModel = struct {
    id: []const u8,
    display_name: []const u8,
    context_length: ?u32,
    max_output_tokens: ?u32,
    /// Model-level declared price. An endpoint's own price overrides it.
    quote: offer.Quote,
    capabilities: offer.CapabilityMatrix,
    controls: []const controls_mod.ControlSpec,
};

pub const ModelCatalog = struct {
    arena: std.heap.ArenaAllocator,
    models: std.ArrayList(CatalogModel) = .empty,

    pub fn deinit(self: *ModelCatalog) void {
        self.models.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn find(self: *const ModelCatalog, id: []const u8) ?*const CatalogModel {
        for (self.models.items) |*candidate| {
            if (std.mem.eql(u8, candidate.id, id)) return candidate;
        }
        return null;
    }
};

pub fn parseModels(allocator: std.mem.Allocator, text: []const u8) AdapterError!ModelCatalog {
    var out = ModelCatalog{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer out.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), text, .{}) catch
        return error.InvalidDocument;
    const list = dataArray(root) orelse return error.InvalidDocument;
    if (list.len > MAX_MODELS) return error.TooManyModels;

    const arena = out.arena.allocator();
    for (list) |item| {
        if (item != .object) return error.InvalidDocument;
        const id = stringOf(item.object.get("id")) orelse return error.InvalidDocument;
        const top_provider = item.object.get("top_provider");
        try out.models.append(allocator, .{
            .id = try dupe(arena, id),
            .display_name = try dupe(arena, stringOf(item.object.get("name")) orelse id),
            .context_length = optionalU32(item.object.get("context_length")),
            .max_output_tokens = if (top_provider) |value| blk: {
                if (value != .object) break :blk null;
                break :blk optionalU32(value.object.get("max_completion_tokens"));
            } else null,
            .quote = try parsePricing(item.object.get("pricing")),
            .capabilities = parseArchitecture(item.object.get("architecture"), item.object.get("supported_parameters")),
            .controls = try parseSupportedParameters(arena, item.object.get("supported_parameters")),
        });
    }
    return out;
}

// ── endpoint catalog ─────────────────────────────────────────────────────────

/// One concrete route behind a canonical model. This is what becomes a channel.
pub const Endpoint = struct {
    /// Upstream provider name as OpenRouter reports it, e.g. "DeepInfra".
    provider_name: []const u8,
    /// Slug derived from `provider_name`; it becomes the `ChannelId`.
    channel_id: Slug,
    /// The exact string the request must carry. Often the canonical model id,
    /// but a router may expose a different one.
    request_model_id: []const u8,
    context_length: ?u32,
    max_output_tokens: ?u32,
    quote: offer.Quote,
    health: offer.Health,
    availability: offer.Availability,
    quantization: ?[]const u8,
    region: ?[]const u8,
    supports_zdr: offer.Tri,
};

pub const EndpointCatalog = struct {
    arena: std.heap.ArenaAllocator,
    canonical_model_id: []const u8 = "",
    endpoints: std.ArrayList(Endpoint) = .empty,

    pub fn deinit(self: *EndpointCatalog) void {
        self.endpoints.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }
};

pub fn parseEndpoints(allocator: std.mem.Allocator, text: []const u8) AdapterError!EndpointCatalog {
    var out = EndpointCatalog{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer out.deinit();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), text, .{}) catch
        return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;
    const data = root.object.get("data") orelse return error.InvalidDocument;
    if (data != .object) return error.InvalidDocument;

    const arena = out.arena.allocator();
    out.canonical_model_id = try dupe(arena, stringOf(data.object.get("id")) orelse return error.InvalidDocument);

    const list_value = data.object.get("endpoints") orelse return error.InvalidDocument;
    if (list_value != .array) return error.InvalidDocument;
    if (list_value.array.items.len > MAX_ENDPOINTS) return error.TooManyEndpoints;

    var seen: usize = 0;
    for (list_value.array.items) |item| {
        if (item != .object) return error.InvalidDocument;
        const provider_name = stringOf(item.object.get("provider_name")) orelse return error.InvalidDocument;
        var channel_id = channelSlug(provider_name) catch return error.InvalidSlug;
        // Two endpoints from one upstream provider differ by quantization or
        // region; the slug has to stay unique or they would collapse into one
        // offer. The suffix search continues until the slug is actually free —
        // a first attempt can itself collide when another provider is literally
        // named "DeepInfra 1", and a duplicate channel id would be rejected far
        // downstream as a malformed profile.
        while (containsChannel(out.endpoints.items, channel_id)) : (seen += 1) {
            if (seen > MAX_ENDPOINTS * 2) return error.InvalidSlug;
            channel_id = disambiguate(provider_name, seen) catch return error.InvalidSlug;
        }
        seen += 1;

        const status = optionalF64(item.object.get("status"));
        try out.endpoints.append(allocator, .{
            .provider_name = try dupe(arena, provider_name),
            .channel_id = channel_id,
            .request_model_id = try dupe(arena, stringOf(item.object.get("model_variant_slug")) orelse
                stringOf(item.object.get("name")) orelse out.canonical_model_id),
            .context_length = optionalU32(item.object.get("context_length")),
            .max_output_tokens = optionalU32(item.object.get("max_completion_tokens")),
            .quote = try parsePricing(item.object.get("pricing")),
            .health = .{
                // OpenRouter reports a numeric status: 0 is normal, negative is
                // degraded/disabled. Absent means *unknown*, which is not the
                // same as healthy — an endpoint that never reported is not one
                // that reported "fine".
                .status = if (status) |value|
                    (if (value < 0) offer.HealthStatus.degraded else offer.HealthStatus.healthy)
                else
                    .unknown,
                .provenance = if (status != null)
                    offer.Provenance.known(.provider_catalog, null)
                else
                    .{},
            },
            .availability = if (status) |value|
                (if (value <= -1000) offer.Availability.unavailable else offer.Availability.available)
            else
                .unknown,
            .quantization = try dupeOptional(arena, stringOf(item.object.get("quantization"))),
            .region = try dupeOptional(arena, stringOf(item.object.get("region"))),
            .supports_zdr = triOf(item.object.get("supports_zdr")),
        });
    }
    return out;
}

/// Merge a model row with its endpoint rows into channel/model declarations.
///
/// Endpoint values win over model values, and only where the endpoint actually
/// has one: an endpoint that omits pricing inherits the model's declared price
/// with `inherited` provenance rather than becoming free.
pub fn buildChannels(
    arena: std.mem.Allocator,
    model: CatalogModel,
    endpoints: []const Endpoint,
) AdapterError![]const profile_mod.ChannelDescriptor {
    const routes = try arena.alloc(profile_mod.ProtocolRoute, 1);
    routes[0] = .{ .protocol = .openai_chat };

    var out = try arena.alloc(profile_mod.ChannelDescriptor, endpoints.len);
    for (endpoints, 0..) |endpoint, index| {
        const models = try arena.alloc(profile_mod.ModelEntry, 1);
        models[0] = .{
            .request_model_id = endpoint.request_model_id,
            .display_name = model.display_name,
            .canonical_model_id = model.id,
            .model_variant = endpoint.quantization,
            .limits = .{
                .context_window = endpoint.context_length orelse model.context_length,
                .max_output_tokens = endpoint.max_output_tokens orelse model.max_output_tokens,
                .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
                .provenance = if (endpoint.context_length != null)
                    offer.Provenance.known(.provider_catalog, null)
                else
                    offer.Provenance.known(.provider_catalog, null).inherit(),
            },
            .capabilities = model.capabilities,
            .quote = if (endpoint.quote.isKnown()) endpoint.quote else inheritQuote(model.quote),
            .availability = endpoint.availability,
            .controls = model.controls,
        };
        out[index] = .{
            .id = endpoint.channel_id,
            .display_name = endpoint.provider_name,
            .base_url = "https://openrouter.ai/api/v1",
            .routes = routes,
            .region = endpoint.region,
            .models = models,
        };
    }
    return out;
}

fn inheritQuote(quote: offer.Quote) offer.Quote {
    return switch (quote) {
        .unknown => .unknown,
        .known => |priced| blk: {
            var copy = priced;
            copy.provenance = priced.provenance.inherit();
            break :blk .{ .known = copy };
        },
    };
}

// ── provider preferences → RoutePolicy ───────────────────────────────────────

/// Compile an OpenRouter `provider` preferences object into a `RoutePolicy`.
///
/// The mapping is deliberately conservative in one direction: `only`/`ignore`
/// and the numeric ceilings become *hard* constraints, because the kernel
/// rejects anything it cannot prove qualifies, while `order` and `sort` become
/// preferences that never reject. Reading a preference as a constraint would
/// silently drop routes the user did not exclude.
pub fn compilePolicy(text: []const u8, allocator: std.mem.Allocator) AdapterError!RoutePolicy {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), text, .{}) catch
        return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;
    const preferences = if (root.object.get("provider")) |value| value else root;
    if (preferences != .object) return error.InvalidDocument;

    var policy = RoutePolicy{};
    policy.only_channels = try channelList(preferences.object.get("only"));
    policy.ignore_channels = try channelList(preferences.object.get("ignore"));
    policy.preferred_order = try channelList(preferences.object.get("order"));
    // OpenRouter's `allow_fallbacks` defaults to true; the kernel's default is
    // the opposite, because a selection that silently tries a second route is
    // not the one the user inspected. The explicit value wins when present.
    policy.fallback_allowed = boolOf(preferences.object.get("allow_fallbacks")) orelse
        (policy.preferred_order.len > 0);
    policy.require_parameters = boolOf(preferences.object.get("require_parameters")) orelse false;

    if (stringOf(preferences.object.get("sort"))) |sort| {
        policy.sort_preference = if (std.mem.eql(u8, sort, "price"))
            .price
        else if (std.mem.eql(u8, sort, "throughput"))
            .throughput
        else if (std.mem.eql(u8, sort, "latency"))
            .latency
        else
            .provider_defined;
    }

    if (stringOf(preferences.object.get("data_collection"))) |collection| {
        policy.data_collection = if (std.mem.eql(u8, collection, "deny"))
            .deny
        else if (std.mem.eql(u8, collection, "allow"))
            .allow
        else
            .unspecified;
    }
    if (boolOf(preferences.object.get("zdr"))) |value| policy.zdr = value;
    if (stringOf(preferences.object.get("region"))) |region| {
        policy.region = selection_mod.RegionText.parse(region) catch return error.ControlTextTooLong;
    }
    if (stringOf(preferences.object.get("quantizations"))) |quant| {
        policy.quantization = selection_mod.QuantizationText.parse(quant) catch return error.ControlTextTooLong;
    } else if (preferences.object.get("quantizations")) |value| {
        // A single-element list is a constraint; several are a preference this
        // policy cannot express, and pretending otherwise would drop routes.
        if (value == .array and value.array.items.len == 1) {
            const text_value = stringOf(value.array.items[0]) orelse return error.InvalidDocument;
            policy.quantization = selection_mod.QuantizationText.parse(text_value) catch
                return error.ControlTextTooLong;
        }
    }

    if (preferences.object.get("max_price")) |max_price| {
        if (max_price != .object) return error.InvalidDocument;
        // OpenRouter's `max_price` is USD per million tokens, per direction.
        // Each direction keeps its own ceiling: collapsing them into one number
        // is wrong whichever way it rounds, and an unspecified direction stays
        // unconstrained rather than inheriting the other one's limit.
        const prompt = optionalF64(max_price.object.get("prompt"));
        const completion = optionalF64(max_price.object.get("completion"));
        if (prompt != null or completion != null) {
            policy.hard_max_price = .{
                .currency = offer.Currency.lit("USD"),
                .billing_unit = .per_million_tokens,
                .max_micros = std.math.maxInt(u64),
                .max_input_micros = if (prompt) |value| try scaledMicros(value, 1_000_000.0) else null,
                .max_output_micros = if (completion) |value| try scaledMicros(value, 1_000_000.0) else null,
            };
        }
    }
    if (optionalU32(preferences.object.get("min_context_window"))) |window| {
        policy.hard_min_context_window = window;
    }
    if (optionalU32(preferences.object.get("max_latency_ms"))) |latency| {
        policy.hard_max_latency_ms = latency;
    }
    if (optionalU32(preferences.object.get("min_throughput_tps"))) |throughput| {
        policy.hard_min_throughput_tps = throughput;
    }
    return policy;
}

// ── router metadata → ActualRouteEvent ───────────────────────────────────────

/// What a response's router metadata says actually happened. Applied on top of
/// the event the kernel already derived from its own resolution, so a mismatch
/// between requested and actual stays visible instead of being overwritten.
pub const RouterObservation = struct {
    /// Upstream provider the router actually used, as a channel slug. A value
    /// rather than a slice: the parse arena does not outlive the call, and an
    /// event payload carries ids, never free-form strings.
    upstream_channel: ?Slug = null,
    usage: offer.Usage = .{},
    cost_micros: ?u64 = null,
    latency_ms: ?u32 = null,
    fallback_attempts: ?u8 = null,
};

pub fn parseRouterMetadata(text: []const u8, allocator: std.mem.Allocator) AdapterError!RouterObservation {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), text, .{}) catch
        return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;

    var out = RouterObservation{};
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            out.usage = .{
                .input_tokens = optionalU64(usage.object.get("prompt_tokens")) orelse 0,
                .output_tokens = optionalU64(usage.object.get("completion_tokens")) orelse 0,
                .cached_input_tokens = optionalU64(usage.object.get("cached_tokens")) orelse 0,
            };
            if (optionalF64(usage.object.get("cost"))) |cost| {
                out.cost_micros = scaledMicros(cost, 1_000_000.0) catch null;
            }
        }
    }
    if (optionalU32(root.object.get("latency_ms"))) |latency| out.latency_ms = latency;
    if (root.object.get("provider")) |value| {
        if (stringOf(value)) |name| out.upstream_channel = channelSlug(name) catch null;
    }
    if (root.object.get("fallbacks")) |value| {
        if (value == .array) out.fallback_attempts = @intCast(@min(value.array.items.len, 255));
    }
    return out;
}

/// Fold an observation into the event the kernel derived. Deliberately does not
/// touch `requested`: what the user asked for is not something the router gets
/// to rewrite.
pub fn applyObservation(
    event: selection_mod.ActualRouteEvent,
    observation: RouterObservation,
) selection_mod.ActualRouteEvent {
    var out = event;
    out.usage = observation.usage;
    out.cost_micros = observation.cost_micros;
    out.latency_ms = observation.latency_ms;
    if (observation.fallback_attempts) |attempts| out.fallback_attempts = attempts;
    // Status is derived, not reported: the router says which providers it tried,
    // and "it fell back" is exactly "it tried more than one". A field carrying a
    // status nothing produces would be decoration.
    if (out.fallback_attempts > 0) out.status = .fell_back;
    return out;
}

// ── shared parsing ───────────────────────────────────────────────────────────

fn dataArray(root: std.json.Value) ?[]const std.json.Value {
    if (root == .array) return root.array.items;
    if (root != .object) return null;
    const data = root.object.get("data") orelse return null;
    if (data != .array) return null;
    return data.array.items;
}

/// OpenRouter prices are decimal strings in USD **per token**. Converting to
/// micro-USD per million tokens keeps the whole pipeline in integers.
fn parsePricing(value: ?std.json.Value) AdapterError!offer.Quote {
    const object = value orelse return .unknown;
    if (object != .object) return .unknown;

    const prompt = try priceField(object.object.get("prompt"));
    const completion = try priceField(object.object.get("completion"));
    if (prompt == null and completion == null) return .unknown;
    return .{ .known = .{
        .currency = offer.Currency.lit("USD"),
        .billing_unit = .per_million_tokens,
        .input_price_micros = prompt,
        .output_price_micros = completion,
        .cached_input_price_micros = try priceField(object.object.get("input_cache_read")),
        .cache_write_price_micros = try priceField(object.object.get("input_cache_write")),
        .provenance = offer.Provenance.known(.provider_catalog, null),
    } };
}

fn priceField(value: ?std.json.Value) AdapterError!?u64 {
    const found = value orelse return null;
    const per_token: f64 = switch (found) {
        .string => |text| blk: {
            if (text.len == 0) return null;
            break :blk std.fmt.parseFloat(f64, text) catch return error.MalformedPrice;
        },
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .null => return null,
        else => return error.MalformedPrice,
    };
    return try scaledMicros(per_token, 1_000_000.0 * 1_000_000.0);
}

/// `value * scale` as an integer, or an error.
///
/// The finiteness check is the load-bearing part: `"prompt": "nan"` or a price
/// large enough to overflow makes `@intFromFloat` illegal behaviour, and a
/// catalog document is exactly the kind of input that can carry either. A
/// comparison against a NaN is false, so the range check alone would not catch
/// it.
fn scaledMicros(value: f64, scale: f64) AdapterError!u64 {
    if (!std.math.isFinite(value) or value < 0) return error.MalformedPrice;
    const scaled = value * scale;
    if (!std.math.isFinite(scaled)) return error.MalformedPrice;
    if (scaled > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.MalformedPrice;
    return @intFromFloat(@round(scaled));
}

fn parseArchitecture(architecture: ?std.json.Value, parameters: ?std.json.Value) offer.CapabilityMatrix {
    var out = offer.CapabilityMatrix{ .provenance = offer.Provenance.known(.provider_catalog, null) };
    out = out.with(.streaming, .supported);
    if (architecture) |value| {
        if (value == .object) {
            if (value.object.get("input_modalities")) |modalities| {
                if (modalities == .array) {
                    var has_image = false;
                    for (modalities.array.items) |item| {
                        if (stringOf(item)) |text| {
                            if (std.mem.eql(u8, text, "image")) has_image = true;
                        }
                    }
                    out = out.with(.vision, if (has_image) .supported else .unsupported);
                }
            }
        }
    }
    if (parameters) |value| {
        if (value == .array) {
            var has_tools = false;
            var has_reasoning = false;
            for (value.array.items) |item| {
                const text = stringOf(item) orelse continue;
                if (std.mem.eql(u8, text, "tools")) has_tools = true;
                if (std.mem.eql(u8, text, "reasoning")) has_reasoning = true;
            }
            out = out.with(.tools, if (has_tools) .supported else .unsupported);
            if (has_reasoning) out = out.with(.reasoning, .supported);
        }
    }
    return out;
}

/// `supported_parameters` names the controls a model accepts. Only the ones the
/// kernel can express as an enumeration become controls; the rest stay absent
/// rather than becoming a control with an invented vocabulary.
fn parseSupportedParameters(
    arena: std.mem.Allocator,
    value: ?std.json.Value,
) AdapterError![]const controls_mod.ControlSpec {
    const list = value orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(controls_mod.ControlSpec) = .empty;
    for (list.array.items) |item| {
        const text = stringOf(item) orelse continue;
        if (!std.mem.eql(u8, text, "reasoning")) continue;
        const values = try arena.alloc([]const u8, 3);
        values[0] = "low";
        values[1] = "medium";
        values[2] = "high";
        out.append(arena, .{
            .id = "reasoning_effort",
            .label = "Reasoning",
            .kind = .enumeration,
            .allowed_values = values,
        }) catch return error.OutOfMemory;
    }
    return out.items;
}

fn channelSlug(provider_name: []const u8) !Slug {
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    var len: usize = 0;
    for (provider_name) |byte| {
        if (len == buffer.len) break;
        const lowered = std.ascii.toLower(byte);
        if ((lowered >= 'a' and lowered <= 'z') or (lowered >= '0' and lowered <= '9')) {
            buffer[len] = lowered;
            len += 1;
        } else if (len > 0 and buffer[len - 1] != '-') {
            buffer[len] = '-';
            len += 1;
        }
    }
    while (len > 0 and buffer[len - 1] == '-') len -= 1;
    if (len == 0) return error.InvalidSlug;
    return Slug.parse(buffer[0..len]);
}

fn disambiguate(provider_name: []const u8, index: usize) !Slug {
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const base = try channelSlug(provider_name);
    const text = std.fmt.bufPrint(&buffer, "{s}-{d}", .{ base.slice(), index }) catch
        return error.InvalidSlug;
    return Slug.parse(text);
}

fn containsChannel(existing: []const Endpoint, id: Slug) bool {
    for (existing) |candidate| if (candidate.channel_id.eql(id)) return true;
    return false;
}

fn channelList(value: ?std.json.Value) AdapterError!selection_mod.ChannelList {
    const list = value orelse return .{};
    if (list != .array) return .{};
    var out = selection_mod.ChannelList{};
    for (list.array.items) |item| {
        const text = stringOf(item) orelse continue;
        const id = channelSlug(text) catch continue;
        out.append(id) catch return error.TooManyChannels;
    }
    return out;
}

fn dupe(arena: std.mem.Allocator, text: []const u8) AdapterError![]const u8 {
    return arena.dupe(u8, text) catch error.OutOfMemory;
}

fn dupeOptional(arena: std.mem.Allocator, text: ?[]const u8) AdapterError!?[]const u8 {
    const value = text orelse return null;
    return try dupe(arena, value);
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn boolOf(value: ?std.json.Value) ?bool {
    const found = value orelse return null;
    return switch (found) {
        .bool => |flag| flag,
        else => null,
    };
}

fn triOf(value: ?std.json.Value) offer.Tri {
    const flag = boolOf(value) orelse return .unknown;
    return if (flag) .supported else .unsupported;
}

/// A JSON number as an integer, or null. The float branch checks finiteness and
/// range *before* converting: `@intFromFloat` on a NaN or an out-of-range value
/// is illegal behaviour, and a fetched document can carry either.
fn integerOf(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |v| v,
        .float => |v| blk: {
            if (!std.math.isFinite(v)) break :blk null;
            if (v < @as(f64, @floatFromInt(std.math.minInt(i64)))) break :blk null;
            if (v > @as(f64, @floatFromInt(std.math.maxInt(i64)))) break :blk null;
            break :blk @intFromFloat(v);
        },
        else => null,
    };
}

fn optionalU32(value: ?std.json.Value) ?u32 {
    const number = integerOf(value orelse return null) orelse return null;
    if (number <= 0 or number > std.math.maxInt(u32)) return null;
    return @intCast(number);
}

fn optionalU64(value: ?std.json.Value) ?u64 {
    const number = integerOf(value orelse return null) orelse return null;
    if (number < 0) return null;
    return @intCast(number);
}

fn optionalF64(value: ?std.json.Value) ?f64 {
    const found = value orelse return null;
    const number: f64 = switch (found) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    // A non-finite value poisons every arithmetic it reaches and makes any
    // later integer conversion illegal, so it never leaves this function.
    return if (std.math.isFinite(number)) number else null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const MODELS_FIXTURE =
    \\{"data": [
    \\  {"id": "deepseek/deepseek-v4", "name": "DeepSeek V4",
    \\   "context_length": 163840,
    \\   "top_provider": {"max_completion_tokens": 65536},
    \\   "architecture": {"input_modalities": ["text"]},
    \\   "supported_parameters": ["tools", "reasoning", "temperature"],
    \\   "pricing": {"prompt": "0.0000004", "completion": "0.0000016", "input_cache_read": "0.0000001"}},
    \\  {"id": "moonshot/kimi-k3", "name": "Kimi K3",
    \\   "architecture": {"input_modalities": ["text", "image"]},
    \\   "supported_parameters": ["tools"]}
    \\]}
;

const ENDPOINTS_FIXTURE =
    \\{"data": {"id": "deepseek/deepseek-v4", "endpoints": [
    \\  {"provider_name": "DeepInfra", "context_length": 131072, "status": 0,
    \\   "quantization": "fp8", "supports_zdr": true,
    \\   "pricing": {"prompt": "0.0000005", "completion": "0.0000018"}},
    \\  {"provider_name": "Together AI", "status": -1,
    \\   "pricing": {"prompt": "0.0000009", "completion": "0.0000029"}},
    \\  {"provider_name": "Fireworks"}
    \\]}}
;

test "models and endpoints are parsed separately and stay separate" {
    const a = testing.allocator;
    var models = try parseModels(a, MODELS_FIXTURE);
    defer models.deinit();
    var endpoints = try parseEndpoints(a, ENDPOINTS_FIXTURE);
    defer endpoints.deinit();

    try testing.expectEqual(@as(usize, 2), models.models.items.len);
    try testing.expectEqual(@as(usize, 3), endpoints.endpoints.items.len);
    // One model, three routes. Merging them would reproduce exactly the
    // "a model name identifies the route" mistake.
    try testing.expectEqualStrings("deepseek/deepseek-v4", endpoints.canonical_model_id);
}

test "prices convert from per-token strings without losing precision to zero" {
    const a = testing.allocator;
    var models = try parseModels(a, MODELS_FIXTURE);
    defer models.deinit();
    const priced = models.find("deepseek/deepseek-v4").?.quote.priced().?;
    // $0.0000004 per token = $0.40 per million tokens = 400_000 micro-USD.
    try testing.expectEqual(@as(?u64, 400_000), priced.input_price_micros);
    try testing.expectEqual(@as(?u64, 1_600_000), priced.output_price_micros);
    try testing.expectEqual(@as(?u64, 100_000), priced.cached_input_price_micros);
    try testing.expectEqual(offer.BillingUnit.per_million_tokens, priced.billing_unit);
    try testing.expectEqualStrings("USD", priced.currency.slice());
}

test "absent endpoint data is unknown, never zero price or unlimited context" {
    const a = testing.allocator;
    var endpoints = try parseEndpoints(a, ENDPOINTS_FIXTURE);
    defer endpoints.deinit();

    const fireworks = endpoints.endpoints.items[2];
    try testing.expectEqualStrings("Fireworks", fireworks.provider_name);
    try testing.expect(!fireworks.quote.isKnown());
    try testing.expectEqual(@as(?u32, null), fireworks.context_length);
    // An endpoint that never reported a status is not one that reported "fine".
    try testing.expectEqual(offer.HealthStatus.unknown, fireworks.health.status);
    try testing.expectEqual(offer.Availability.unknown, fireworks.availability);
    try testing.expectEqual(offer.Tri.unknown, fireworks.supports_zdr);

    const together = endpoints.endpoints.items[1];
    try testing.expectEqual(offer.HealthStatus.degraded, together.health.status);
    try testing.expectEqual(offer.Source.provider_catalog, together.health.provenance.source);
}

test "a malformed price is an error rather than a free-looking route" {
    const a = testing.allocator;
    const text =
        \\{"data": [{"id": "x/y", "pricing": {"prompt": "not-a-number"}}]}
    ;
    try testing.expectError(error.MalformedPrice, parseModels(a, text));
}

test "an endpoint's own values win, and an absent one inherits rather than resets" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var models = try parseModels(a, MODELS_FIXTURE);
    defer models.deinit();
    var endpoints = try parseEndpoints(a, ENDPOINTS_FIXTURE);
    defer endpoints.deinit();

    const channels = try buildChannels(
        arena.allocator(),
        models.find("deepseek/deepseek-v4").?.*,
        endpoints.endpoints.items,
    );
    try testing.expectEqual(@as(usize, 3), channels.len);

    // DeepInfra declares its own context and price.
    const deepinfra = channels[0].models[0];
    try testing.expect(channels[0].id.eqlText("deepinfra"));
    try testing.expectEqual(@as(?u32, 131_072), deepinfra.limits.context_window);
    try testing.expectEqual(@as(?u64, 500_000), deepinfra.quote.priced().?.input_price_micros);
    try testing.expectEqualStrings("fp8", deepinfra.model_variant.?);

    // Together AI declares no context: it inherits the model's, and provenance
    // says so rather than claiming the endpoint confirmed it.
    const together = channels[1].models[0];
    try testing.expectEqual(@as(?u32, 163_840), together.limits.context_window);
    try testing.expectEqual(offer.Freshness.inherited, together.limits.provenance.freshness);

    // Fireworks declares neither: the price is inherited, and inherited is not
    // the same as measured.
    const fireworks = channels[2].models[0];
    try testing.expectEqual(@as(?u64, 400_000), fireworks.quote.priced().?.input_price_micros);
    try testing.expectEqual(offer.Freshness.inherited, fireworks.quote.priced().?.provenance.freshness);
}

test "capabilities come from declared modalities and parameters, never a guess" {
    const a = testing.allocator;
    var models = try parseModels(a, MODELS_FIXTURE);
    defer models.deinit();

    const deepseek = models.find("deepseek/deepseek-v4").?;
    try testing.expectEqual(offer.Tri.supported, deepseek.capabilities.get(.tools));
    try testing.expectEqual(offer.Tri.supported, deepseek.capabilities.get(.reasoning));
    try testing.expectEqual(offer.Tri.unsupported, deepseek.capabilities.get(.vision));
    // A model declaring reasoning gets the control; one that does not, does not.
    try testing.expectEqual(@as(usize, 1), deepseek.controls.len);
    try testing.expectEqualStrings("reasoning_effort", deepseek.controls[0].id);

    const kimi = models.find("moonshot/kimi-k3").?;
    try testing.expectEqual(offer.Tri.supported, kimi.capabilities.get(.vision));
    try testing.expectEqual(@as(usize, 0), kimi.controls.len);
    // Nothing was said about caching, so nothing is claimed.
    try testing.expectEqual(offer.Tri.unknown, kimi.capabilities.get(.caching));
}

test "provider preferences compile into hard constraints and soft preferences" {
    const a = testing.allocator;
    const policy = try compilePolicy(
        \\{"provider": {
        \\  "only": ["DeepInfra", "Together AI"],
        \\  "ignore": ["Fireworks"],
        \\  "order": ["DeepInfra"],
        \\  "allow_fallbacks": true,
        \\  "require_parameters": true,
        \\  "sort": "throughput",
        \\  "data_collection": "deny",
        \\  "zdr": true,
        \\  "region": "eu",
        \\  "quantizations": ["fp8"],
        \\  "max_price": {"prompt": 1.5, "completion": 6},
        \\  "min_context_window": 100000,
        \\  "max_latency_ms": 800,
        \\  "min_throughput_tps": 40}}
    , a);

    try testing.expectEqual(@as(u8, 2), policy.only_channels.len);
    try testing.expect(policy.only_channels.contains(Slug.lit("deepinfra")));
    try testing.expect(policy.only_channels.contains(Slug.lit("together-ai")));
    try testing.expect(policy.ignore_channels.contains(Slug.lit("fireworks")));
    try testing.expect(policy.preferred_order.contains(Slug.lit("deepinfra")));
    try testing.expect(policy.fallback_allowed);
    try testing.expect(policy.require_parameters);
    try testing.expectEqual(selection_mod.SortPreference.throughput, policy.sort_preference);
    try testing.expectEqual(selection_mod.DataCollection.deny, policy.data_collection);
    try testing.expectEqual(@as(?bool, true), policy.zdr);
    try testing.expectEqualStrings("eu", policy.region.?.slice());
    try testing.expectEqualStrings("fp8", policy.quantization.?.slice());
    // The ceiling carries its currency and unit; a bare number could not be
    // compared against an offer priced in another currency.
    // Each direction keeps its own ceiling rather than being folded into one.
    try testing.expectEqual(@as(u64, 1_500_000), policy.hard_max_price.?.inputCeiling());
    try testing.expectEqual(@as(u64, 6_000_000), policy.hard_max_price.?.outputCeiling());
    try testing.expectEqualStrings("USD", policy.hard_max_price.?.currency.slice());
    try testing.expectEqual(@as(?u32, 100_000), policy.hard_min_context_window);
    try testing.expectEqual(@as(?u32, 800), policy.hard_max_latency_ms);
    try testing.expectEqual(@as(?u32, 40), policy.hard_min_throughput_tps);
}

test "fallback stays off unless the preferences ask for it" {
    const a = testing.allocator;
    // The kernel's default is no fallback: a selection that silently tries a
    // second route is not the one the user inspected.
    const bare = try compilePolicy("{\"provider\": {}}", a);
    try testing.expect(!bare.fallback_allowed);

    const denied = try compilePolicy("{\"provider\": {\"allow_fallbacks\": false, \"order\": [\"A\"]}}", a);
    try testing.expect(!denied.fallback_allowed);
}

test "a compiled policy actually rejects and orders real offers" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var models = try parseModels(a, MODELS_FIXTURE);
    defer models.deinit();
    var endpoints = try parseEndpoints(a, ENDPOINTS_FIXTURE);
    defer endpoints.deinit();
    const channels = try buildChannels(
        arena.allocator(),
        models.find("deepseek/deepseek-v4").?.*,
        endpoints.endpoints.items,
    );

    const registry_mod = @import("registry.zig");
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const kinds = [_]profile_mod.CredentialKind{.api_key};
    try registry.register(.{
        .id = Slug.lit("openrouter"),
        .implementation_id = Slug.lit("openrouter"),
        .display_name = "OpenRouter",
        .channels = channels,
        .accepted_credential_kinds = &kinds,
        .default_channel = channels[0].id,
    });
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("openrouter") });
    defer catalog.deinit();
    try testing.expectEqual(@as(usize, 3), catalog.items().len);

    // `ignore` must actually remove a route, not merely deprioritize it.
    const policy = try compilePolicy("{\"provider\": {\"ignore\": [\"Fireworks\"], \"allow_fallbacks\": true}}", a);
    var selection = try selection_mod.RuntimeSelection.auto("deepseek/deepseek-v4", policy, .session);
    const resolution = try selection_mod.resolve(&catalog, selection);
    try testing.expectEqual(@as(u8, 2), resolution.len);
    for (resolution.items()) |candidate| {
        try testing.expect(!candidate.channel_id.eqlText("fireworks"));
    }

    // A per-direction ceiling constrains only that direction. DeepInfra's
    // prompt price is 0.50 and Fireworks inherits 0.40, so a 0.45 prompt
    // ceiling keeps Fireworks and drops the other two — even though every
    // route's *completion* price is far above 0.45.
    const cheap = try compilePolicy(
        "{\"provider\": {\"max_price\": {\"prompt\": 0.45}, \"allow_fallbacks\": true}}",
        a,
    );
    selection = try selection_mod.RuntimeSelection.auto("deepseek/deepseek-v4", cheap, .session);
    const affordable = try selection_mod.resolve(&catalog, selection);
    try testing.expectEqual(@as(u8, 1), affordable.len);
    try testing.expect(affordable.primary().channel_id.eqlText("fireworks"));

    // And an output ceiling nothing satisfies rejects every route rather than
    // quietly picking the cheapest.
    const impossible = try compilePolicy(
        "{\"provider\": {\"max_price\": {\"completion\": 0.1}, \"allow_fallbacks\": true}}",
        a,
    );
    selection = try selection_mod.RuntimeSelection.auto("deepseek/deepseek-v4", impossible, .session);
    try testing.expectError(
        error.AllCandidatesRejected,
        selection_mod.resolve(&catalog, selection),
    );
}

test "router metadata fills the actual route without rewriting what was requested" {
    const a = testing.allocator;
    const observation = try parseRouterMetadata(
        \\{"provider": "DeepInfra", "latency_ms": 640,
        \\ "fallbacks": [{"provider": "Together AI"}],
        \\ "usage": {"prompt_tokens": 1200, "completion_tokens": 300, "cached_tokens": 200, "cost": 0.0042}}
    , a);

    try testing.expect(observation.upstream_channel.?.eqlText("deepinfra"));
    try testing.expectEqual(@as(u64, 1200), observation.usage.input_tokens);
    try testing.expectEqual(@as(u64, 200), observation.usage.cached_input_tokens);
    try testing.expectEqual(@as(?u64, 4_200), observation.cost_micros);
    try testing.expectEqual(@as(?u32, 640), observation.latency_ms);
    try testing.expectEqual(@as(?u8, 1), observation.fallback_attempts);

    const pinned = ids.OfferId{ .digest = @splat(0x33) };
    const base = selection_mod.ActualRouteEvent{
        .requested = .{ .pinned = pinned },
        .actual_offer_id = ids.OfferId{ .digest = @splat(0x44) },
        .actual_offer_revision = 1,
        .provider_id = Slug.lit("openrouter"),
        .channel_id = Slug.lit("deepinfra"),
        .protocol = "openai_chat",
    };
    const merged = applyObservation(base, observation);
    // What the user asked for is not something the router gets to rewrite.
    try testing.expect(merged.requested.pinned.eql(pinned));
    try testing.expectEqual(@as(u8, 1), merged.fallback_attempts);
    try testing.expectEqual(selection_mod.RouteStatus.fell_back, merged.status);
    try testing.expectEqual(@as(?u64, 4_200), merged.cost_micros);
}

test "two endpoints from one upstream provider stay distinct offers" {
    const a = testing.allocator;
    var endpoints = try parseEndpoints(a,
        \\{"data": {"id": "x/y", "endpoints": [
        \\  {"provider_name": "DeepInfra", "quantization": "fp8"},
        \\  {"provider_name": "DeepInfra", "quantization": "bf16"}
        \\]}}
    );
    defer endpoints.deinit();
    try testing.expectEqual(@as(usize, 2), endpoints.endpoints.items.len);
    // A collapsed slug would silently drop one of the two routes.
    try testing.expect(!endpoints.endpoints.items[0].channel_id.eql(endpoints.endpoints.items[1].channel_id));
}

test "hostile numbers are rejected rather than converted" {
    const a = testing.allocator;
    // `@intFromFloat` on a NaN or an out-of-range value is illegal behaviour,
    // and a fetched catalog is exactly the kind of document that can carry one.
    try testing.expectError(error.MalformedPrice, parseModels(a,
        \\{"data": [{"id": "x/y", "pricing": {"prompt": "nan"}}]}
    ));
    try testing.expectError(error.MalformedPrice, parseModels(a,
        \\{"data": [{"id": "x/y", "pricing": {"prompt": "inf"}}]}
    ));
    try testing.expectError(error.MalformedPrice, parseModels(a,
        \\{"data": [{"id": "x/y", "pricing": {"prompt": "1e300"}}]}
    ));
    try testing.expectError(error.MalformedPrice, parseModels(a,
        \\{"data": [{"id": "x/y", "pricing": {"prompt": "-0.5"}}]}
    ));

    // A non-finite context length is dropped rather than converted, leaving the
    // limit unknown — which admission already fails closed on.
    var models = try parseModels(a,
        \\{"data": [{"id": "x/y", "context_length": 1e400}]}
    );
    defer models.deinit();
    try testing.expectEqual(@as(?u32, null), models.find("x/y").?.context_length);

    // And a policy ceiling that cannot be represented is an error, not a
    // silently enormous one that admits everything.
    try testing.expectError(error.MalformedPrice, compilePolicy(
        "{\"provider\": {\"max_price\": {\"prompt\": 1e308}}}",
        a,
    ));
}

test "three endpoints from one provider get three distinct channels" {
    const a = testing.allocator;
    var endpoints = try parseEndpoints(a,
        \\{"data": {"id": "x/y", "endpoints": [
        \\  {"provider_name": "DeepInfra"},
        \\  {"provider_name": "DeepInfra 1"},
        \\  {"provider_name": "DeepInfra"}
        \\]}}
    );
    defer endpoints.deinit();
    try testing.expectEqual(@as(usize, 3), endpoints.endpoints.items.len);

    // A duplicate channel id survives all the way to profile validation and
    // fails the whole ingest, so the suffix search has to actually find a free
    // slug rather than try once.
    for (endpoints.endpoints.items, 0..) |left, i| {
        for (endpoints.endpoints.items[i + 1 ..]) |right| {
            try testing.expect(!left.channel_id.eql(right.channel_id));
        }
    }
}
