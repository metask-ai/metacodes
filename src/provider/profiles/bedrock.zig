//! Amazon Bedrock provider profile (native Converse API).
//!
//! Integration notes — the Converse wire, AWS event-stream framing, thinking
//! fields per hosted vendor, signed-reasoning passback, cache points, and
//! their sources — live in `src/api/dialects/bedrock.zig`; the transport is
//! `src/api/bedrock_client.zig`. This file is the route data.
//!
//! One channel per region, each an origin: the transport appends
//! `/model/{modelId}/converse-stream` itself (`EndpointShape.base_origin`).
//! Authentication is a Bedrock API key sent as `Authorization: Bearer`
//! (`AWS_BEARER_TOKEN_BEDROCK`); SigV4 is not implemented.
//!
//! The static inventory is a small, current Claude line-up addressed through
//! cross-region inference profiles (`us.` / `eu.` / `apac.` prefixes, the
//! documented naming of system-defined profiles). Newer Claude models are
//! invocable on demand only through such a profile. The authoritative list
//! for an account is its own catalog: `provider_catalogs` with
//! `"kind": "bedrock"` ingests ListFoundationModels and ListInferenceProfiles
//! (`src/provider/bedrock_catalog.zig`). Quotes stay `unknown`.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");
const model_limits = @import("../../util/model.zig");

const Slug = ids.Slug;

pub fn runtimeOrigin(comptime region: []const u8) []const u8 {
    return "https://bedrock-runtime." ++ region ++ ".amazonaws.com";
}

/// Adaptive thinking takes low / medium / high / max on Claude 4.6;
/// `none` switches thinking off.
const CLAUDE_EFFORTS = [_][]const u8{ "none", "low", "medium", "high", "max" };

const CLAUDE_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &CLAUDE_EFFORTS,
}};

const CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported)
    .with(.caching, .supported)
    .with(.vision, .supported);

fn claude(comptime geo: []const u8, comptime base_id: []const u8, comptime bare: []const u8, comptime display_name: []const u8) profile.ModelEntry {
    return .{
        .request_model_id = geo ++ ".anthropic." ++ base_id,
        .display_name = display_name,
        .canonical_model_id = "anthropic/" ++ bare,
        .upstream_model_id = "anthropic." ++ base_id,
        .limits = .{
            // 200K is the standard window on Bedrock; the 1M window is a
            // separate opt-in.
            .context_window = 200_000,
            .max_output_tokens = model_limits.limitsFor(bare).default,
            .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
            .provenance = offer.Provenance.known(.builtin_profile, null),
        },
        .capabilities = CAPABILITIES,
        .controls = &CLAUDE_CONTROLS,
        .dialect = .claude,
    };
}

fn lineup(comptime geo: []const u8) [2]profile.ModelEntry {
    return .{
        claude(geo, "claude-sonnet-4-6", "claude-sonnet-4-6", "Claude Sonnet 4.6 (Bedrock)"),
        claude(geo, "claude-opus-4-6-v1", "claude-opus-4-6", "Claude Opus 4.6 (Bedrock)"),
    };
}

const US_MODELS = lineup("us");
const EU_MODELS = lineup("eu");
const APAC_MODELS = lineup("apac");

const ROUTES = [_]profile.ProtocolRoute{.{ .protocol = .bedrock_converse }};

fn channel(comptime region: []const u8, comptime display_name: []const u8, comptime models: []const profile.ModelEntry) profile.ChannelDescriptor {
    return .{
        .id = Slug.lit(region),
        .display_name = display_name,
        .base_url = runtimeOrigin(region),
        .routes = &ROUTES,
        .region = region,
        .models = models,
    };
}

const CHANNELS = [_]profile.ChannelDescriptor{
    channel("us-east-1", "Bedrock · US East (N. Virginia)", &US_MODELS),
    channel("us-west-2", "Bedrock · US West (Oregon)", &US_MODELS),
    channel("eu-central-1", "Bedrock · Europe (Frankfurt)", &EU_MODELS),
    channel("ap-northeast-1", "Bedrock · Asia Pacific (Tokyo)", &APAC_MODELS),
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "AWS_BEARER_TOKEN_BEDROCK", .kind = .api_key, .canonical = true },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("bedrock"),
    .implementation_id = Slug.lit("bedrock"),
    .display_name = "Amazon Bedrock",
    .aliases = &.{"aws-bedrock"},
    .channels = &CHANNELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("us-east-1"),
};

test "bedrock profile: origins per region, Converse route, Claude through inference profiles" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://bedrock-runtime.us-east-1.amazonaws.com",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .bedrock_converse, null, &buffer),
    );
    try std.testing.expectEqual(profile.EndpointShape.base_origin, profile.Protocol.shape(.bedrock_converse));
    try std.testing.expectEqualStrings("us.anthropic.claude-sonnet-4-6", US_MODELS[0].request_model_id);
    try std.testing.expectEqualStrings("eu.anthropic.claude-opus-4-6-v1", EU_MODELS[1].request_model_id);
    try std.testing.expectEqual(@as(?u32, 64_000), US_MODELS[1].limits.max_output_tokens);
    for (CHANNELS) |c| for (c.models) |m| {
        try std.testing.expectEqual(profile.Vendor.claude, m.dialect.?);
        const spec = controls.findSpec(m.controls, "reasoning_effort").?;
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    };
}
