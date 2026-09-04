//! Metask provider profile — the historical default path.
//!
//! Preserves today's behaviour exactly: the Anthropic messages wire protocol
//! against `napi.metask-ai.com`, `METASK_API_KEY` as the environment alias, and
//! bearer authentication. Output limits reuse `util/model.zig` so the profile
//! cannot drift from the table the request builder already consults.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const model_limits = @import("../../util/model.zig");
const pricing = @import("../../util/pricing.zig");

const Slug = ids.Slug;

pub const BASE_URL = "https://napi.metask-ai.com";

/// Anthropic-family context window when the provider catalog has not answered
/// yet. Matches the existing `api/catalog.zig` fallback, so the offer view and
/// the request path agree.
const CLAUDE_CONTEXT_WINDOW: u32 = 200_000;

/// USD per million tokens → micro-USD per million tokens.
fn microsPerMillion(usd_per_mtok: f64) u64 {
    return @intFromFloat(@round(usd_per_mtok * 1_000_000.0));
}

/// Quote built from `util/pricing.zig` — the same table `UsageTotals.costUsd`
/// already reports with. Reusing it is the point: two independent price tables
/// would eventually disagree, and the picker would then show a number the cost
/// line contradicts.
///
/// `estimated` is true because these are metacodes' own published-rate figures,
/// not a bill from the provider. That distinction is exactly why `Quote` has
/// the flag: a quote that cannot say which it is invites being read as billed
/// cost.
fn claudeQuote(comptime request_model_id: []const u8) offer.Quote {
    const rates = comptime pricing.rateFor(request_model_id);
    return .{ .known = .{
        .currency = offer.Currency.lit("USD"),
        .billing_unit = .per_million_tokens,
        .input_price_micros = comptime microsPerMillion(rates.input_per_mtok),
        .output_price_micros = comptime microsPerMillion(rates.output_per_mtok),
        .cached_input_price_micros = comptime microsPerMillion(rates.cache_read_per_mtok),
        .cache_write_price_micros = comptime microsPerMillion(rates.cache_write_per_mtok),
        .estimated = true,
        .provenance = offer.Provenance.known(.builtin_profile, null),
    } };
}

fn claudeEntry(
    comptime request_model_id: []const u8,
    comptime display_name: []const u8,
) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "anthropic/" ++ request_model_id,
        .limits = .{
            .context_window = CLAUDE_CONTEXT_WINDOW,
            .max_output_tokens = model_limits.limitsFor(request_model_id).default,
            .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
            .provenance = offer.Provenance.known(.builtin_profile, null),
        },
        .capabilities = (offer.CapabilityMatrix{
            .provenance = offer.Provenance.known(.builtin_profile, null),
        })
            .with(.tools, .supported)
            .with(.streaming, .supported)
            .with(.caching, .supported)
            .with(.reasoning, .supported)
            .with(.vision, .supported),
        .quote = claudeQuote(request_model_id),
    };
}

const MODELS = [_]profile.ModelEntry{
    claudeEntry("claude-opus-4-6", "Claude Opus 4.6"),
    claudeEntry("claude-opus-4-5", "Claude Opus 4.5"),
    claudeEntry("claude-sonnet-4-6", "Claude Sonnet 4.6"),
    claudeEntry("claude-sonnet-4-20250514", "Claude Sonnet 4"),
    claudeEntry("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
    claudeEntry("claude-3-5-haiku-20241022", "Claude Haiku 3.5"),
};

const ROUTES = [_]profile.ProtocolRoute{
    .{ .protocol = .anthropic_messages },
};

const CHANNELS = [_]profile.ChannelDescriptor{.{
    .id = Slug.lit("default"),
    .display_name = "Metask",
    .base_url = BASE_URL,
    .routes = &ROUTES,
}};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{ .api_key, .metask_oauth };

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "METASK_API_KEY", .kind = .api_key, .canonical = true },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("metask"),
    .implementation_id = Slug.lit("metask"),
    .display_name = "Metask",
    .aliases = &.{"anthropic"},
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("default"),
    .oauth_token_url = "https://metask-ai.com/api/oauth/token",
    .oauth_device_authorization_url = "https://metask-ai.com/api/oauth/device/code",
    .oauth_client_id = "metacodes",
};

test "metask profile keeps the historical endpoint and environment alias" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    const url = try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, null, &buffer);
    try std.testing.expectEqualStrings("https://napi.metask-ai.com/v1/messages", url);
    try std.testing.expectEqualStrings("METASK_API_KEY", PROFILE.canonicalEnvAlias(.api_key).?);
}

test "metask legacy profile keeps the historical messages route" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://napi.metask-ai.com/v1/messages",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, null, &buffer),
    );
    try std.testing.expect(CHANNELS[0].route(.openai_chat) == null);
}

test "metask model limits come from the shared output-limit table" {
    for (MODELS) |entry| {
        try std.testing.expectEqual(
            @as(?u32, model_limits.limitsFor(entry.request_model_id).default),
            entry.limits.max_output_tokens,
        );
    }
}

test "the profile quote agrees with the cost line the session already reports" {
    // Two price tables would drift, and the picker would then contradict
    // `/cost`. This asserts they are the same numbers, not similar ones.
    for (MODELS) |entry| {
        const rates = pricing.rateFor(entry.request_model_id);
        const priced = entry.quote.priced().?;
        try std.testing.expectEqualStrings("USD", priced.currency.slice());
        try std.testing.expectEqual(microsPerMillion(rates.input_per_mtok), priced.input_price_micros.?);
        try std.testing.expectEqual(microsPerMillion(rates.output_per_mtok), priced.output_price_micros.?);
        try std.testing.expectEqual(microsPerMillion(rates.cache_read_per_mtok), priced.cached_input_price_micros.?);
        try std.testing.expectEqual(microsPerMillion(rates.cache_write_per_mtok), priced.cache_write_price_micros.?);
        // A published rate is not a provider bill, and must not read as one.
        try std.testing.expect(priced.estimated);
    }
}

test "an estimate over a mixed-cache turn matches the reported cost" {
    const usage = offer.Usage{
        .input_tokens = 1_000_000,
        .output_tokens = 200_000,
        .cached_input_tokens = 400_000,
        .cache_write_tokens = 100_000,
    };
    const opus = MODELS[0];
    const micros = opus.quote.estimateMicros(usage).?;

    const rates = pricing.rateFor(opus.request_model_id);
    const fresh = usage.input_tokens - usage.cached_input_tokens - usage.cache_write_tokens;
    const expected_usd = pricing.computeCost(
        rates,
        fresh,
        usage.output_tokens,
        usage.cached_input_tokens,
        usage.cache_write_tokens,
    );
    const estimate_usd = @as(f64, @floatFromInt(micros)) / 1_000_000.0;
    try std.testing.expectApproxEqAbs(expected_usd, estimate_usd, 0.000_001);
}
