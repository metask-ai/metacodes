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

const Slug = ids.Slug;

pub const BASE_URL = "https://napi.metask-ai.com";

/// Anthropic-family context window when the provider catalog has not answered
/// yet. Matches the existing `api/catalog.zig` fallback, so the offer view and
/// the request path agree.
const CLAUDE_CONTEXT_WINDOW: u32 = 200_000;

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

const ROUTES = [_]profile.ProtocolRoute{.{ .protocol = .anthropic_messages }};

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
};

test "metask profile keeps the historical endpoint and environment alias" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    const url = try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, null, &buffer);
    try std.testing.expectEqualStrings("https://napi.metask-ai.com/v1/messages", url);
    try std.testing.expectEqualStrings("METASK_API_KEY", PROFILE.canonicalEnvAlias(.api_key).?);
}

test "metask model limits come from the shared output-limit table" {
    for (MODELS) |entry| {
        try std.testing.expectEqual(
            @as(?u32, model_limits.limitsFor(entry.request_model_id).default),
            entry.limits.max_output_tokens,
        );
    }
}
