//! Alibaba Qwen (Model Studio / DashScope) provider profile.
//!
//! Integration notes — `enable_thinking`, the per-model thinking defaults,
//! regional endpoints, and their sources — live in `src/api/dialects/qwen.zig`;
//! this file is the route data.
//!
//! Beijing and Singapore are separate accounts whose keys do not cross. Each
//! has an OpenAI-compatible surface (`/compatible-mode/v1`) and an
//! Anthropic-compatible one (`/apps/anthropic`). The route policies require
//! those path markers rather than fixing the host, so a workspace-scoped
//! endpoint (`https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`)
//! is a valid `--base-url` override while a wrong-protocol path is not.
//!
//! Quotes stay `unknown`: prices differ by region and by context tier.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const CN_OPENAI_BASE = "https://dashscope.aliyuncs.com/compatible-mode/v1";
pub const INTL_OPENAI_BASE = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
pub const CN_ANTHROPIC_BASE = "https://dashscope.aliyuncs.com/apps/anthropic";
pub const INTL_ANTHROPIC_BASE = "https://dashscope-intl.aliyuncs.com/apps/anthropic";

/// Qwen has a switch, not levels: `none` turns thinking off, `high` on.
const EFFORTS = [_][]const u8{ "none", "high" };

const CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Thinking",
    .kind = .enumeration,
    .allowed_values = &EFFORTS,
}};

/// 1,000,000-token window and 131,072 output tokens for the Qwen 3.8 line in
/// both regions.
const LIMITS = offer.EffectiveLimits{
    .context_window = 1_000_000,
    .max_output_tokens = 131_072,
    .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
    .provenance = offer.Provenance.known(.builtin_profile, null),
};

const CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported)
    .with(.reasoning_content, .supported)
    .with(.vision, .supported);

const MODELS = [_]profile.ModelEntry{
    .{
        .request_model_id = "qwen3.8-max",
        .display_name = "Qwen3.8 Max",
        .canonical_model_id = "qwen/qwen3.8-max",
        .limits = LIMITS,
        .capabilities = CAPABILITIES,
        .controls = &CONTROLS,
    },
    .{
        .request_model_id = "qwen3.8-flash",
        .display_name = "Qwen3.8 Flash",
        .canonical_model_id = "qwen/qwen3.8-flash",
        .limits = LIMITS,
        .capabilities = CAPABILITIES,
        .controls = &CONTROLS,
    },
};

const OPENAI_REQUIRED = [_][]const u8{"/compatible-mode/v1"};
const ANTHROPIC_REQUIRED = [_][]const u8{"/apps/anthropic"};

const OPENAI_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .policy = .{ .required_path_fragments = &OPENAI_REQUIRED },
    .dialect = .qwen,
}};

const ANTHROPIC_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .anthropic_messages,
    .policy = .{ .required_path_fragments = &ANTHROPIC_REQUIRED },
    .dialect = .qwen,
}};

const CHANNELS = [_]profile.ChannelDescriptor{
    .{
        .id = Slug.lit("cn-openai"),
        .display_name = "Qwen · Beijing · OpenAI wire",
        .base_url = CN_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "cn",
    },
    .{
        .id = Slug.lit("intl-openai"),
        .display_name = "Qwen · Singapore · OpenAI wire",
        .base_url = INTL_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "intl",
    },
    .{
        .id = Slug.lit("cn-anthropic"),
        .display_name = "Qwen · Beijing · Anthropic wire",
        .base_url = CN_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "cn",
    },
    .{
        .id = Slug.lit("intl-anthropic"),
        .display_name = "Qwen · Singapore · Anthropic wire",
        .base_url = INTL_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "intl",
    },
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "DASHSCOPE_API_KEY", .kind = .api_key, .canonical = true },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("qwen"),
    .implementation_id = Slug.lit("qwen"),
    .display_name = "Alibaba Qwen",
    .aliases = &.{ "dashscope", "bailian" },
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("cn-openai"),
};

test "qwen profile: workspace endpoints pass, cross-protocol overrides do not" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer),
    );
    try std.testing.expectEqualStrings(
        "https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, "https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", &buffer),
    );
    try std.testing.expectError(
        error.MissingRequiredEndpointPath,
        CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, "https://dashscope.aliyuncs.com/apps/anthropic", &buffer),
    );
    for (CHANNELS) |channel| for (channel.routes) |route| {
        try std.testing.expectEqual(profile.Vendor.qwen, route.dialect.?);
    };
}
