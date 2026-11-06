//! OpenAI provider profile.
//!
//! Integration notes live in `src/api/dialects/openai.zig`; this file is the
//! route data.
//!
//! One channel exposing both OpenAI wire families. The protocol stays an
//! explicit route choice — it is never inferred from the base URL or the model
//! name, which is the same rule `types.OpenAIProtocol` already documents.
//!
//! Codex OAuth shares this implementation but is a distinct credential kind, so
//! a Codex token can never be silently used as a plain OpenAI key and vice
//! versa. The OAuth *lifecycle* (device/PKCE flow, refresh, rotated-refresh
//! persistence) is delivery slice P1; P0 declares the accepted kinds and the
//! transport auth shape.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const BASE_URL = "https://api.openai.com/v1";

/// RFC 6749 token endpoint. Refresh and rotated-refresh persistence run through
/// `provider/oauth.zig`; only the URL is profile data.
pub const OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token";

/// RFC 6749 authorization endpoint, the companion of the token endpoint above.
/// It is what makes `metacodes login --provider openai` a real browser flow
/// (issue #33) rather than a request to produce a token response by hand.
pub const OAUTH_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";

/// The levels the GPT-6 models accept above "no reasoning" (developers.openai.com
/// /api/docs/models/gpt-6-astra, gpt-6.1-sol, gpt-6-luna, 2026-10). `none` is
/// deliberately not offered: the neutral `none` sends no effort at all, which
/// leaves the model's own default rather than switching reasoning off, and
/// GPT-6 Astra and Sol refuse `none` anyway.
const GPT6_EFFORTS = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };

const GPT6_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &GPT6_EFFORTS,
    .cost_latency_warning = "xhigh and max cost more and answer slower",
}};

/// Tool calling needs the Responses API on these models: GPT-6.1 Sol takes no
/// tools on Chat Completions, and GPT-6 Luna calls functions there only with
/// reasoning off. A coding agent sends tools on every turn, so Chat
/// Completions is not offered for them.
const RESPONSES_ONLY = [_]profile.Protocol{.openai_responses};

/// A current GPT-6 model: 1,050,000-token window with at most 922,000 input
/// and 128,000 output tokens, the same for all three (2026-10 model pages).
fn gpt6(comptime request_model_id: []const u8, comptime display_name: []const u8) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "openai/" ++ request_model_id,
        .limits = .{
            .context_window = 1_050_000,
            .max_input_tokens = 922_000,
            .max_output_tokens = 128_000,
            .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
            .provenance = offer.Provenance.known(.builtin_profile, null),
        },
        .capabilities = (offer.CapabilityMatrix{
            .provenance = offer.Provenance.known(.builtin_profile, null),
        })
            .with(.tools, .supported)
            .with(.streaming, .supported)
            .with(.reasoning, .supported),
        .controls = &GPT6_CONTROLS,
        .protocols = &RESPONSES_ONLY,
        .dialect = .openai,
    };
}

/// The current frontier line-up, flagship first. gpt-4o / gpt-4o-mini / o3
/// are deprecated and o3-mini was shut down on 2026-10-23
/// (developers.openai.com/api/docs/deprecations); a session can still name
/// any model with `--model`, which keeps the user's string on this channel.
const MODELS = [_]profile.ModelEntry{
    gpt6("gpt-6-astra", "GPT-6 Astra"),
    gpt6("gpt-6.1-sol", "GPT-6.1 Sol"),
    gpt6("gpt-6-luna", "GPT-6 Luna"),
};

const ROUTES = [_]profile.ProtocolRoute{
    .{ .protocol = .openai_chat },
    .{ .protocol = .openai_responses },
};

const CHANNELS = [_]profile.ChannelDescriptor{.{
    .id = Slug.lit("default"),
    .display_name = "OpenAI",
    .base_url = BASE_URL,
    .routes = &ROUTES,
}};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{
    .api_key,
    .openai_oauth,
    .openai_codex_oauth,
};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "OPENAI_API_KEY", .kind = .api_key, .canonical = true },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("openai"),
    .implementation_id = Slug.lit("openai"),
    .display_name = "OpenAI",
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("default"),
    .oauth_token_url = OAUTH_TOKEN_URL,
    .oauth_authorize_url = OAUTH_AUTHORIZE_URL,
    // Deliberately undeclared: the OAuth client an installation presents is
    // registered by whoever runs it, and inventing one here would send every
    // user's first exchange to a client that is not theirs. `metacodes login
    // --provider openai --client-id <id>` supplies it, and a `custom_providers`
    // entry persists it.
    .oauth_client_id = null,
};

test "openai profile routes both wire families from one channel" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer),
    );
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/responses",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_responses, null, &buffer),
    );
}

test "codex oauth is a distinct accepted kind, not an openai key alias" {
    var seen_codex = false;
    for (PROFILE.accepted_credential_kinds) |kind| {
        if (kind == .openai_codex_oauth) seen_codex = true;
    }
    try std.testing.expect(seen_codex);
    // No environment alias grants the Codex kind: it only arrives through the
    // credential store or an explicit reference.
    for (PROFILE.env_aliases) |alias| {
        try std.testing.expect(alias.kind != .openai_codex_oauth);
    }
}

test "the profile declares a token endpoint for the OAuth kinds it accepts" {
    // A profile that accepts an OAuth kind and declares no token endpoint
    // cannot refresh, which surfaces as a mysterious expiry hours later.
    var accepts_oauth = false;
    for (PROFILE.accepted_credential_kinds) |kind| {
        if (@import("../oauth.zig").servesKind(kind)) accepts_oauth = true;
    }
    try std.testing.expect(accepts_oauth);
    try std.testing.expect(PROFILE.oauth_token_url != null);
}

test "the profile declares a browser entry point for its first token" {
    // Without an authorization endpoint the only way in is an out-of-band
    // token response, which is the gap issue #33 reports.
    try std.testing.expect(PROFILE.declaresInteractiveOAuth());
    try std.testing.expectEqualStrings(
        "https://auth.openai.com/oauth/authorize",
        PROFILE.oauth_authorize_url.?,
    );
}

test "the GPT-6 models are Responses-only, bounded, and offer their reasoning levels" {
    try profile.validateProfile(PROFILE);
    try std.testing.expectEqual(@as(usize, 3), MODELS.len);
    for (MODELS) |model| {
        try std.testing.expect(model.servesProtocol(.openai_responses));
        try std.testing.expect(!model.servesProtocol(.openai_chat));
        try std.testing.expectEqual(@as(?u32, 1_050_000), model.limits.context_window);
        try std.testing.expectEqual(@as(?u32, 128_000), model.limits.max_output_tokens);
        const spec = controls.findSpec(model.controls, "reasoning_effort").?;
        try std.testing.expectEqual(controls.ValueKind.enumeration, spec.kind);
        try std.testing.expectEqualStrings("max", spec.allowed_values[spec.allowed_values.len - 1]);
        // Every offered level is one the neutral effort type can carry.
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    }
}
