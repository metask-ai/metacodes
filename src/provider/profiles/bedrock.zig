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
//! system-defined cross-region inference profiles: newer Claude models are
//! invocable on demand only through one (in-Region only in eu-west-2). Each
//! channel names the profiles its Region can call, as the AWS model cards list
//! them (checked 2026-11-06):
//!
//! | Channel | Sonnet 4.6 | Opus 4.6 |
//! |---|---|---|
//! | us-east-1, us-west-2 | `us.` | `us.` |
//! | eu-central-1 | `eu.` | `eu.` |
//! | ap-northeast-1 | `jp.` (Tokyo/Osaka) | `global.` (Opus 4.6 has no `jp.` profile) |
//!
//! There is no `apac.` profile for either model. The authoritative list for
//! an account is its own catalog: `provider_catalogs` with `"kind": "bedrock"`
//! ingests ListFoundationModels and ListInferenceProfiles
//! (`src/provider/bedrock_catalog.zig`). Quotes stay `unknown`.
//!
//! Sources: https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html
//! and .../model-card-anthropic-claude-opus-4-6.html.

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

/// The two models through the inference profiles a channel's Region calls:
/// `sonnet_geo` / `opus_geo` are the profile prefixes (see the table above).
fn lineup(comptime sonnet_geo: []const u8, comptime opus_geo: []const u8) [2]profile.ModelEntry {
    return .{
        claude(sonnet_geo, "claude-sonnet-4-6", "claude-sonnet-4-6", "Claude Sonnet 4.6 (Bedrock" ++ routing(sonnet_geo) ++ ")"),
        claude(opus_geo, "claude-opus-4-6-v1", "claude-opus-4-6", "Claude Opus 4.6 (Bedrock" ++ routing(opus_geo) ++ ")"),
    };
}

/// A global profile routes outside the channel's geography; the name says so.
fn routing(comptime geo: []const u8) []const u8 {
    return if (std.mem.eql(u8, geo, "global")) ", global routing" else "";
}

const US_MODELS = lineup("us", "us");
const EU_MODELS = lineup("eu", "eu");
const TOKYO_MODELS = lineup("jp", "global");

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
    channel("ap-northeast-1", "Bedrock · Asia Pacific (Tokyo)", &TOKYO_MODELS),
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "AWS_BEARER_TOKEN_BEDROCK", .kind = .api_key, .canonical = true },
};

/// What a user without a key is told (`login --provider bedrock`, and the
/// missing-credential help): the one credential this transport sends.
pub const KEY_NOTE = "Amazon Bedrock takes a Bedrock API key here (AWS_BEARER_TOKEN_BEDROCK), sent as a bearer token. AWS access keys, SigV4 request signing, AWS profiles and SSO are not supported.";

/// The AWS page on Bedrock API keys. No unbilled endpoint is known to accept
/// the key as a check, so a pasted key is stored unchecked.
const KEY_PAGES = [_]profile.KeyPage{.{
    .id = Slug.lit("aws"),
    .label = "Amazon Bedrock API keys (AWS documentation)",
    .url = "https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html",
}};

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
    .api_key_setup = .{ .kind = .api_key, .pages = &KEY_PAGES, .note = KEY_NOTE },
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
        // No `apac.` inference profile exists for these models.
        try std.testing.expect(!std.mem.startsWith(u8, m.request_model_id, "apac."));
        const spec = controls.findSpec(m.controls, "reasoning_effort").?;
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    };
}

test "bedrock profile: each channel's model ids are inference profiles its Region can call" {
    const expected = [_]struct { region: []const u8, sonnet: []const u8, opus: []const u8 }{
        .{ .region = "us-east-1", .sonnet = "us.anthropic.claude-sonnet-4-6", .opus = "us.anthropic.claude-opus-4-6-v1" },
        .{ .region = "us-west-2", .sonnet = "us.anthropic.claude-sonnet-4-6", .opus = "us.anthropic.claude-opus-4-6-v1" },
        .{ .region = "eu-central-1", .sonnet = "eu.anthropic.claude-sonnet-4-6", .opus = "eu.anthropic.claude-opus-4-6-v1" },
        // Tokyo: Sonnet 4.6 through the Japan profile; Opus 4.6 has only the global one.
        .{ .region = "ap-northeast-1", .sonnet = "jp.anthropic.claude-sonnet-4-6", .opus = "global.anthropic.claude-opus-4-6-v1" },
    };
    try std.testing.expectEqual(expected.len, CHANNELS.len);
    var buffer: [256]u8 = undefined;
    for (expected, CHANNELS) |want, c| {
        try std.testing.expectEqualStrings(want.region, c.region.?);
        try std.testing.expect(c.id.eqlText(want.region));
        const origin = try c.endpointFor(PROFILE.endpoint_policy, .bedrock_converse, null, &buffer);
        try std.testing.expect(std.mem.startsWith(u8, origin, "https://bedrock-runtime."));
        try std.testing.expect(std.mem.indexOf(u8, origin, want.region) != null);
        try std.testing.expectEqual(@as(usize, 2), c.models.len);
        try std.testing.expectEqualStrings(want.sonnet, c.models[0].request_model_id);
        try std.testing.expectEqualStrings(want.opus, c.models[1].request_model_id);
    }
    try std.testing.expectEqualStrings("Claude Opus 4.6 (Bedrock, global routing)", TOKYO_MODELS[1].display_name);
}

test "bedrock profile: a user without a key is told what key, and what is not supported" {
    const setup = PROFILE.api_key_setup.?;
    try std.testing.expectEqual(profile.CredentialKind.api_key, setup.kind);
    try std.testing.expect(std.mem.indexOf(u8, setup.note.?, "AWS_BEARER_TOKEN_BEDROCK") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup.note.?, "SigV4") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup.note.?, "access keys") != null);
}
