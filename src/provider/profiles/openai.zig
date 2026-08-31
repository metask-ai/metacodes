//! OpenAI provider profile.
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

const Slug = ids.Slug;

pub const BASE_URL = "https://api.openai.com/v1";

/// RFC 6749 token endpoint. Refresh and rotated-refresh persistence run through
/// `provider/oauth.zig`; only the URL is profile data.
pub const OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token";

fn entry(
    comptime request_model_id: []const u8,
    comptime display_name: []const u8,
    comptime reasoning: offer.Tri,
) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "openai/" ++ request_model_id,
        .capabilities = (offer.CapabilityMatrix{
            .provenance = offer.Provenance.known(.builtin_profile, null),
        })
            .with(.tools, .supported)
            .with(.streaming, .supported)
            .with(.reasoning, reasoning),
    };
}

const MODELS = [_]profile.ModelEntry{
    entry("gpt-4o", "GPT-4o", .unsupported),
    entry("gpt-4o-mini", "GPT-4o mini", .unsupported),
    entry("o3", "o3", .supported),
    entry("o3-mini", "o3-mini", .supported),
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
