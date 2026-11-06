//! MiniMax provider profile.
//!
//! Integration notes — `thinking.type`, `reasoning_effort` (M3.1 only),
//! `reasoning_split`, and their sources — live in
//! `src/api/dialects/minimax.zig`; this file is the route data.
//!
//! China (`api.minimax.cn`) and global (`api.minimax.io`) are separate
//! accounts. Each has an OpenAI-chat (`/v1`) and an Anthropic-compatible
//! (`/anthropic`) surface. Quotes stay `unknown` until a catalog supplies them.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const CN_OPENAI_BASE = "https://api.minimax.cn/v1";
pub const GLOBAL_OPENAI_BASE = "https://api.minimax.io/v1";
pub const CN_ANTHROPIC_BASE = "https://api.minimax.cn/anthropic";
pub const GLOBAL_ANTHROPIC_BASE = "https://api.minimax.io/anthropic";

/// M3.1 always thinks and takes five levels; `none` is refused by the API,
/// so it is not offered.
const M31_EFFORTS = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };

const M31_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &M31_EFFORTS,
}};

/// M3 thinks adaptively or not at all; levels are ignored.
const M3_EFFORTS = [_][]const u8{ "none", "high" };

const M3_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Thinking",
    .kind = .enumeration,
    .allowed_values = &M3_EFFORTS,
}};

/// 1M window ("1M long context", M3.1-Flash). Output is declared as 131,072,
/// the recommended value: this repository never sends `max_completion_tokens`
/// although the API accepts up to 524,288.
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
        .request_model_id = "MiniMax-M3.1-Flash",
        .display_name = "MiniMax M3.1 Flash",
        .canonical_model_id = "minimax/minimax-m3.1-flash",
        .limits = LIMITS,
        .capabilities = CAPABILITIES,
        .controls = &M31_CONTROLS,
    },
    .{
        .request_model_id = "MiniMax-M3",
        .display_name = "MiniMax M3",
        .canonical_model_id = "minimax/minimax-m3",
        .limits = LIMITS,
        .capabilities = CAPABILITIES,
        .controls = &M3_CONTROLS,
    },
};

const OPENAI_REQUIRED = [_][]const u8{"/v1"};
const ANTHROPIC_REQUIRED = [_][]const u8{"/anthropic"};

const OPENAI_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .policy = .{ .required_path_fragments = &OPENAI_REQUIRED },
    .dialect = .minimax,
}};

const ANTHROPIC_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .anthropic_messages,
    .policy = .{ .required_path_fragments = &ANTHROPIC_REQUIRED },
    .dialect = .minimax,
}};

const CHANNELS = [_]profile.ChannelDescriptor{
    .{
        .id = Slug.lit("cn-openai"),
        .display_name = "MiniMax · China · OpenAI wire",
        .base_url = CN_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "cn",
    },
    .{
        .id = Slug.lit("global-openai"),
        .display_name = "MiniMax · Global · OpenAI wire",
        .base_url = GLOBAL_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "global",
    },
    .{
        .id = Slug.lit("cn-anthropic"),
        .display_name = "MiniMax · China · Anthropic wire",
        .base_url = CN_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "cn",
    },
    .{
        .id = Slug.lit("global-anthropic"),
        .display_name = "MiniMax · Global · Anthropic wire",
        .base_url = GLOBAL_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "global",
    },
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "MINIMAX_API_KEY", .kind = .api_key, .canonical = true },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("minimax"),
    .implementation_id = Slug.lit("minimax"),
    .display_name = "MiniMax",
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("cn-openai"),
};

test "minimax profile: China and global, each route declaring the MiniMax dialect" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.minimax.cn/v1/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer),
    );
    try std.testing.expectEqualStrings(
        "https://api.minimax.io/anthropic/v1/messages",
        try CHANNELS[3].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, null, &buffer),
    );
    for (CHANNELS) |channel| for (channel.routes) |route| {
        try std.testing.expectEqual(profile.Vendor.minimax, route.dialect.?);
    };
    for (MODELS) |model| {
        const spec = controls.findSpec(model.controls, "reasoning_effort").?;
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    }
}
