//! Capability-matrix fixture (issue #16, acceptance: controls and validation).
//!
//! Five models from five vendors, each with *provider-declared* capabilities,
//! its own control vocabulary, and its own limits — and no rule anywhere that
//! reads a model name. The point of the fixture is that nothing here could be
//! derived: "GLM returns `reasoning_content`", "Kimi has no reasoning control",
//! "GPT names its efforts differently from DeepSeek", "MiniMax exposes a
//! latency tier and the others do not" are declarations, and a name-inference
//! rule that got them right for these five would get the sixth wrong.
//!
//! Timestamps are part of the declaration. A capability observed at some point
//! is a different claim from one the vendor documents, and `Provenance` is what
//! keeps them distinguishable.

const std = @import("std");
const ids = @import("ids.zig");
const offer = @import("offer.zig");
const controls_mod = @import("controls.zig");
const profile_mod = @import("profile.zig");
const registry_mod = @import("registry.zig");

const Slug = ids.Slug;
const testing = std.testing;

/// Declaration time. A fixed value rather than "now": a fixture whose
/// provenance changes every run cannot assert on it.
const DECLARED_AT: i64 = 1_772_000_000;

fn declared() offer.Provenance {
    return offer.Provenance.known(.builtin_profile, DECLARED_AT);
}

// ── control vocabularies, one per vendor ─────────────────────────────────────

const DEEPSEEK_CONTROLS = [_]controls_mod.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning",
    .kind = .enumeration,
    .allowed_values = &.{ "low", "medium", "high" },
}};

const GLM_CONTROLS = [_]controls_mod.ControlSpec{.{
    // Same concept, different vocabulary: GLM speaks of thinking being on or
    // off, not of an effort level.
    .id = "thinking",
    .label = "Thinking",
    .kind = .enumeration,
    .allowed_values = &.{ "enabled", "disabled" },
}};

const GPT_CONTROLS = [_]controls_mod.ControlSpec{
    .{
        .id = "reasoning_effort",
        .label = "Reasoning",
        .kind = .enumeration,
        // A vocabulary that overlaps DeepSeek's without matching it.
        .allowed_values = &.{ "minimal", "low", "medium", "high" },
        .cost_latency_warning = "higher cost and latency",
    },
    .{
        .id = "service_tier",
        .label = "Service tier",
        .kind = .enumeration,
        .allowed_values = &.{ "auto", "default", "flex" },
    },
};

const MINIMAX_CONTROLS = [_]controls_mod.ControlSpec{.{
    // Serving latency is a separate control from reasoning: the kernel must not
    // assume "fast" means "less reasoning".
    .id = "latency_tier",
    .label = "Latency",
    .kind = .enumeration,
    .allowed_values = &.{ "standard", "priority" },
}};

// ── the matrix ───────────────────────────────────────────────────────────────

fn entry(
    comptime request_model_id: []const u8,
    comptime display_name: []const u8,
    comptime canonical: []const u8,
    capabilities: offer.CapabilityMatrix,
    limits: offer.EffectiveLimits,
    controls: []const controls_mod.ControlSpec,
) profile_mod.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = canonical,
        .capabilities = capabilities,
        .limits = limits,
        .controls = controls,
    };
}

fn base() offer.CapabilityMatrix {
    return (offer.CapabilityMatrix{ .provenance = declared() })
        .with(.streaming, .supported)
        .with(.tools, .supported);
}

const MODELS = [_]profile_mod.ModelEntry{
    entry(
        "deepseek-v4",
        "DeepSeek V4",
        "deepseek/deepseek-v4",
        base().with(.reasoning, .supported).with(.vision, .unsupported).with(.caching, .supported),
        .{ .context_window = 163_840, .max_output_tokens = 65_536, .provenance = declared() },
        &DEEPSEEK_CONTROLS,
    ),
    entry(
        "glm-5.3",
        "GLM-5.3",
        "zai/glm-5.3",
        // GLM returns a peer `reasoning_content` field rather than a thinking
        // block. Two distinct capabilities, because a client that emits one
        // wire feature for the other produces a request the provider rejects.
        base().with(.reasoning, .supported).with(.reasoning_content, .supported).with(.vision, .supported),
        .{ .context_window = 200_000, .max_output_tokens = 128_000, .provenance = declared() },
        &GLM_CONTROLS,
    ),
    entry(
        "kimi-k3",
        "Kimi K3",
        "moonshot/kimi-k3",
        // No reasoning at all: `unsupported` is a declaration, and it is not
        // the same as `unknown`.
        base().with(.reasoning, .unsupported).with(.vision, .supported),
        .{ .context_window = 256_000, .provenance = declared() },
        &.{},
    ),
    entry(
        "gpt-5.6",
        "GPT-5.6",
        "openai/gpt-5.6",
        base().with(.reasoning, .supported).with(.vision, .supported).with(.structured_output, .supported),
        .{ .context_window = 400_000, .max_output_tokens = 128_000, .provenance = declared() },
        &GPT_CONTROLS,
    ),
    entry(
        "minimax-m3",
        "MiniMax M3",
        "minimax/minimax-m3",
        // Nothing is claimed about caching or structured output; unknown stays
        // unknown rather than being filled in by resemblance to a neighbour.
        base().with(.vision, .unsupported),
        .{ .context_window = 1_000_000, .provenance = declared() },
        &MINIMAX_CONTROLS,
    ),
};

const ROUTES = [_]profile_mod.ProtocolRoute{
    .{ .protocol = .openai_chat },
    .{ .protocol = .anthropic_messages },
};

const CHANNELS = [_]profile_mod.ChannelDescriptor{
    .{
        .id = Slug.lit("standard"),
        .display_name = "Matrix · standard",
        .base_url = "https://matrix.example.com/v1",
        .routes = &ROUTES,
        .models = &MODELS,
    },
    .{
        .id = Slug.lit("long-context"),
        .display_name = "Matrix · long context",
        .base_url = "https://long.matrix.example.com/v1",
        .routes = &ROUTES,
        .models = &MODELS,
        // Channel-specific narrowing: the same models, served with a tighter
        // output cap and no caching on this endpoint.
        .limits = .{ .max_output_tokens = 8_192, .provenance = declared() },
        .capabilities = (offer.CapabilityMatrix{ .provenance = declared() }).with(.caching, .unsupported),
    },
};

const CREDENTIAL_KINDS = [_]profile_mod.CredentialKind{.api_key};

pub const PROFILE = profile_mod.ProviderProfile{
    .id = Slug.lit("capability-matrix"),
    .implementation_id = Slug.lit("capability-matrix"),
    .display_name = "Capability matrix fixture",
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .default_channel = Slug.lit("standard"),
};

fn findOffer(
    catalog: *const registry_mod.OfferCatalog,
    model: []const u8,
    channel: []const u8,
) !*const offer.ModelOffer {
    for (catalog.items()) |*candidate| {
        if (!std.mem.eql(u8, candidate.request_model_id, model)) continue;
        if (!candidate.channel_id.eqlText(channel)) continue;
        return candidate;
    }
    // An error, not `unreachable`: a fixture that drifts out of sync with the
    // profile should fail the test that reads it, not abort the whole run.
    return error.FixtureOfferMissing;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "five vendors, five capability declarations, no name inference" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    try registry.register(PROFILE);
    var catalog = try registry.buildCatalog(a, .{ .only_provider = PROFILE.id });
    defer catalog.deinit();

    const deepseek = try findOffer(&catalog, "deepseek-v4", "standard");
    const glm = try findOffer(&catalog, "glm-5.3", "standard");
    const kimi = try findOffer(&catalog, "kimi-k3", "standard");
    const gpt = try findOffer(&catalog, "gpt-5.6", "standard");
    const minimax = try findOffer(&catalog, "minimax-m3", "standard");

    // Reasoning differs three ways across five models, and only a declaration
    // could tell them apart.
    try testing.expectEqual(offer.Tri.supported, deepseek.capabilities.get(.reasoning));
    try testing.expectEqual(offer.Tri.unsupported, kimi.capabilities.get(.reasoning));
    try testing.expectEqual(offer.Tri.unknown, minimax.capabilities.get(.reasoning));

    // GLM's peer `reasoning_content` is a separate capability from reasoning
    // itself; conflating them produces a request the provider rejects.
    try testing.expectEqual(offer.Tri.supported, glm.capabilities.get(.reasoning_content));
    try testing.expectEqual(offer.Tri.unknown, deepseek.capabilities.get(.reasoning_content));

    // Unknown is not unsupported, and neither is filled in by resemblance.
    try testing.expectEqual(offer.Tri.unknown, minimax.capabilities.get(.caching));
    try testing.expectEqual(offer.Tri.supported, gpt.capabilities.get(.structured_output));
    try testing.expectEqual(offer.Tri.unknown, kimi.capabilities.get(.structured_output));

    // Every declaration is timestamped and attributed, so "the vendor documents
    // this" stays distinguishable from "something observed it once". Freshness
    // is `inherited` on an offer because the channel narrowed the model's
    // matrix — carried down a scope boundary, not re-confirmed here.
    for ([_]*const offer.ModelOffer{ deepseek, glm, kimi, gpt, minimax }) |candidate| {
        try testing.expect(candidate.capabilities.provenance.isUsable());
        try testing.expectEqual(@as(?i64, DECLARED_AT), candidate.capabilities.provenance.observed_at);
        try testing.expectEqual(offer.Source.builtin_profile, candidate.capabilities.provenance.source);
    }
    // The declaration itself is `known`; only the narrowed copy is inherited.
    try testing.expectEqual(offer.Freshness.known, MODELS[0].capabilities.provenance.freshness);
}

test "reasoning vocabularies differ, and a value from the wrong one is refused" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    try registry.register(PROFILE);
    var catalog = try registry.buildCatalog(a, .{ .only_provider = PROFILE.id });
    defer catalog.deinit();

    const deepseek = try findOffer(&catalog, "deepseek-v4", "standard");
    const glm = try findOffer(&catalog, "glm-5.3", "standard");
    const gpt = try findOffer(&catalog, "gpt-5.6", "standard");

    // `minimal` is GPT's vocabulary, not DeepSeek's. A shared enum would have
    // accepted it here and produced a request DeepSeek rejects.
    var values = controls_mod.ControlValues{};
    try values.set("reasoning_effort", try controls_mod.Value.fromText("minimal"));
    // `minimal` survives revalidation against GPT and is cleared against
    // DeepSeek: a shared enum would have accepted it for both and produced a
    // request DeepSeek rejects.
    try testing.expect(!controls_mod.revalidate(values, gpt.controls).changed());
    try testing.expectEqual(@as(usize, 1), controls_mod.revalidate(values, deepseek.controls).clearedItems().len);

    // GLM does not have a reasoning *effort* at all; it has a thinking switch,
    // so the control is cleared rather than translated.
    try testing.expectEqual(@as(usize, 1), controls_mod.revalidate(values, glm.controls).clearedItems().len);
    var thinking = controls_mod.ControlValues{};
    try thinking.set("thinking", try controls_mod.Value.fromText("enabled"));
    try testing.expect(!controls_mod.revalidate(thinking, glm.controls).changed());
    try testing.expectEqual(@as(usize, 1), controls_mod.revalidate(thinking, deepseek.controls).clearedItems().len);
}

test "a latency tier is present on one model and absent on the rest" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    try registry.register(PROFILE);
    var catalog = try registry.buildCatalog(a, .{ .only_provider = PROFILE.id });
    defer catalog.deinit();

    const minimax = try findOffer(&catalog, "minimax-m3", "standard");
    const deepseek = try findOffer(&catalog, "deepseek-v4", "standard");
    const gpt = try findOffer(&catalog, "gpt-5.6", "standard");

    try testing.expect(controls_mod.findSpec(minimax.controls, "latency_tier") != null);
    try testing.expect(controls_mod.findSpec(deepseek.controls, "latency_tier") == null);
    // GPT has a service tier, which is a *different* control from a latency
    // tier — the kernel owns no vocabulary that could merge them.
    try testing.expect(controls_mod.findSpec(gpt.controls, "service_tier") != null);
    try testing.expect(controls_mod.findSpec(gpt.controls, "latency_tier") == null);

    // Serving latency and reasoning are separate controls: setting one must not
    // be readable as setting the other.
    var latency = controls_mod.ControlValues{};
    try latency.set("latency_tier", try controls_mod.Value.fromText("priority"));
    try testing.expect(!controls_mod.revalidate(latency, minimax.controls).changed());
    try testing.expect(latency.get("reasoning_effort") == null);
}

test "each model appears once per protocol, and the channel narrows both" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    try registry.register(PROFILE);
    var catalog = try registry.buildCatalog(a, .{ .only_provider = PROFILE.id });
    defer catalog.deinit();

    // Two channels × two protocols × five models: every combination is its own
    // offer, because protocol and endpoint are part of route identity.
    try testing.expectEqual(@as(usize, 20), catalog.items().len);

    var protocols_seen: usize = 0;
    for (catalog.items()) |item| {
        if (!std.mem.eql(u8, item.request_model_id, "gpt-5.6")) continue;
        if (!item.channel_id.eqlText("standard")) continue;
        protocols_seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), protocols_seen);

    const standard = try findOffer(&catalog, "glm-5.3", "standard");
    const narrow = try findOffer(&catalog, "glm-5.3", "long-context");
    // Channel-specific limits narrow the model's own, and the model keeps its
    // context window because the channel said nothing about it.
    try testing.expectEqual(@as(?u32, 128_000), standard.limits.max_output_tokens);
    try testing.expectEqual(@as(?u32, 8_192), narrow.limits.max_output_tokens);
    try testing.expectEqual(standard.limits.context_window, narrow.limits.context_window);
    // A channel may remove a capability the model declares.
    try testing.expectEqual(offer.Tri.unsupported, narrow.capabilities.get(.caching));
}
