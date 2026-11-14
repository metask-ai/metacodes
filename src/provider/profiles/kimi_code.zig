//! Kimi Code provider profile: the Kimi coding subscription.
//!
//! Integration notes — the Kimi dialect, the thinking parameters per model, and
//! their sources — live in `src/api/dialects/kimi.zig`; this file is the route
//! data.
//!
//! Kimi Code is part of a Kimi membership, not the Moonshot open platform
//! (`kimi`): keys come from the Kimi Code Console, requests count against the
//! membership's quota, and the base URLs differ. Kimi's error reference says
//! the two "are two separate systems — keys and Base URLs are not
//! interchangeable", so the profile has its own credential kind, and every
//! route requires the `/coding/v1` path marker, which no open-platform URL
//! carries: a `--base-url` override cannot land on the pay-as-you-go platform.
//!
//! Kimi documents one OpenAI-protocol base URL per host that serves both
//! Responses and Chat Completions, on a China and an overseas host. Each wire
//! is its own channel, so a listed model stays unambiguous on the default
//! channel:
//!
//! ```text
//! cn-responses      https://api.kimi.com/coding/v1   openai_responses   (default)
//! cn-chat           https://api.kimi.com/coding/v1   openai_chat
//! global-responses  https://api.kimi.ai/coding/v1    openai_responses
//! global-chat       https://api.kimi.ai/coding/v1    openai_chat
//! ```
//!
//! Responses is the default: Kimi asks tools that support it to use it, and its
//! Codex guide configures it (`wire_api = "responses"`). The Chat Completions
//! channels carry the same models with the Kimi dialect's `reasoning_content`
//! passback, which Kimi Code requires on assistant tool-call messages while
//! thinking is on.
//!
//! Not declared: the Anthropic-compatible surface (`https://api.kimi.com/coding/`).
//! Kimi documents it for Claude Code but not how a Messages request turns
//! thinking on. K3.1 Pro refuses a request with thinking off (HTTP 400), and the
//! other models then answer as K2.8 Preview without thinking. The Kimi dialect
//! sends no `thinking` object on that wire, which is right for the open
//! platform, where thinking is always on, and may read as "off" here.
//!
//! Context windows are the ones every plan that offers the model gets. K3.1 Pro
//! and K3 serve 1,048,576 tokens only on Pro / Allegretto and above and 262,144
//! on Plus / Moderato (a longer request is refused with HTTP 403), so they are
//! declared at 262,144; K3.1 Pro Highspeed is offered on Pro / Allegretto and
//! above only and is declared at its full window. No output limit is
//! documented, so none is declared.
//!
//! Every quote stays `unknown`, as for the GLM Coding Plan: the user pays a
//! membership fee, and a per-token price would be a fabricated number.
//!
//! Sources (2026-11): https://www.kimi.com/code/docs/en/kimi-code/models.html,
//! https://www.kimi.com/code/docs/en/third-party-tools/codex.html,
//! https://www.kimi.com/code/docs/en/kimi-code/error-reference.html.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const CN_BASE = "https://api.kimi.com/coding/v1";
pub const GLOBAL_BASE = "https://api.kimi.ai/coding/v1";

/// The path every Kimi Code OpenAI-protocol URL carries and no open-platform
/// URL does.
pub const CODING_FRAGMENT = "/coding/v1";

/// Where a key is created. The English and Chinese documentation link the same
/// Console for both hosts.
pub const CONSOLE_URL = "https://www.kimi.com/code/console";

/// Thinking effort on every model that takes one: low / high / max, the
/// server's own default when none is sent (high for K3.1 Pro and K3, max for
/// K2.8 Preview). Thinking is never switched off: K3.1 Pro refuses it, and
/// the others would answer as another model.
const EFFORTS = [_][]const u8{ "low", "high", "max" };

const EFFORT_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &EFFORTS,
}};

/// Every model takes images (k3-256k images only, the rest video too, which
/// this repository does not send).
const CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported)
    .with(.reasoning_content, .supported)
    .with(.vision, .supported);

const WINDOW_1M: u32 = 1_048_576;
const WINDOW_256K: u32 = 262_144;

fn windowOf(comptime tokens: u32) offer.EffectiveLimits {
    return .{
        .context_window = tokens,
        .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
        .provenance = offer.Provenance.known(.builtin_profile, null),
    };
}

fn model(
    comptime request_model_id: []const u8,
    comptime display_name: []const u8,
    comptime window: u32,
    comptime model_controls: []const controls.ControlSpec,
) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "moonshotai/" ++ request_model_id,
        .limits = windowOf(window),
        .capabilities = CAPABILITIES,
        .controls = model_controls,
    };
}

/// The six model ids of the subscription (models.html, 2026-11), flagship
/// first. Which ones an account may call depends on its plan; a model outside
/// it is refused with HTTP 403.
const MODELS = [_]profile.ModelEntry{
    // K3.1 Pro: thinking only.
    model("k3.1-pro", "Kimi K3.1 Pro", WINDOW_256K, &EFFORT_CONTROLS),
    // K3.1 Pro at about 2–3× the speed and 2× the quota; Pro / Allegretto and above.
    model("k3.1-pro-highspeed", "Kimi K3.1 Pro Highspeed", WINDOW_1M, &EFFORT_CONTROLS),
    model("k3", "Kimi K3", WINDOW_256K, &EFFORT_CONTROLS),
    // K3 with a 256K window at about half the quota; images only.
    model("k3-256k", "Kimi K3 256K", WINDOW_256K, &EFFORT_CONTROLS),
    // Points at K2.8 Preview (2026-11); on every plan with Kimi Code.
    model("kimi-for-coding", "Kimi for Coding", WINDOW_1M, &EFFORT_CONTROLS),
    // K2.7 Code Highspeed: thinking always on, no effort levels, so no control.
    model("kimi-for-coding-highspeed", "Kimi for Coding Highspeed", WINDOW_256K, &.{}),
};

const REQUIRED = [_][]const u8{CODING_FRAGMENT};

// Both wires speak the Kimi dialect (`src/api/dialects/kimi.zig`).
const RESPONSES_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_responses,
    .policy = .{ .required_path_fragments = &REQUIRED },
    .dialect = .kimi,
}};

const CHAT_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .policy = .{ .required_path_fragments = &REQUIRED },
    .dialect = .kimi,
}};

const CHANNELS = [_]profile.ChannelDescriptor{
    .{
        .id = Slug.lit("cn-responses"),
        .display_name = "Kimi Code · China · Responses wire",
        .base_url = CN_BASE,
        .routes = &RESPONSES_ROUTES,
        .region = "cn",
        .plan = "coding",
    },
    .{
        .id = Slug.lit("cn-chat"),
        .display_name = "Kimi Code · China · Chat Completions wire",
        .base_url = CN_BASE,
        .routes = &CHAT_ROUTES,
        .region = "cn",
        .plan = "coding",
    },
    .{
        .id = Slug.lit("global-responses"),
        .display_name = "Kimi Code · Global · Responses wire",
        .base_url = GLOBAL_BASE,
        .routes = &RESPONSES_ROUTES,
        .region = "global",
        .plan = "coding",
    },
    .{
        .id = Slug.lit("global-chat"),
        .display_name = "Kimi Code · Global · Chat Completions wire",
        .base_url = GLOBAL_BASE,
        .routes = &CHAT_ROUTES,
        .region = "global",
        .plan = "coding",
    },
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.kimi_code_api_key};

/// The key is checked by listing the subscription's models, the call Kimi's
/// own CLI makes with a Console key: 401 without a valid key, and not a model
/// call. Each page checks on its own host; the Console is the same.
const KEY_PAGES = [_]profile.KeyPage{
    .{
        .id = Slug.lit("cn"),
        .label = "China · Kimi Code Console",
        .url = CONSOLE_URL,
        .check_url = CN_BASE ++ "/models",
        .region = "cn",
    },
    .{
        .id = Slug.lit("global"),
        .label = "Global · Kimi Code Console",
        .url = CONSOLE_URL,
        .check_url = GLOBAL_BASE ++ "/models",
        .region = "global",
    },
};

const KEY_SETUP = profile.ApiKeySetup{
    .kind = .kimi_code_api_key,
    .pages = &KEY_PAGES,
    .note = "Create the key in the Kimi Code Console. A Moonshot open-platform key does not work here: they are separate accounts.",
};

/// `KIMI_CODE_API_KEY` is canonical. `KIMI_API_KEY` is the name Kimi's own
/// Codex and Hermes guides give the subscription key, so it belongs here and
/// not to the open-platform profile, where a subscription key would be sent to
/// another account.
const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "KIMI_CODE_API_KEY", .kind = .kimi_code_api_key, .canonical = true },
    .{ .name = "KIMI_API_KEY", .kind = .kimi_code_api_key },
};

/// Kimi Code error classification (error-reference.html, 2026-11).
///
/// Only the transient answers retry: "We're receiving too many requests", "The
/// engine is currently overloaded", the concurrent-request limit (which asks
/// to wait for the requests in flight), and 5xx. A refused or expired key, a
/// plan without the model or its 1M window, and an exhausted 5-hour, weekly or
/// monthly quota or Extra Usage balance fail at once: the reference says
/// retrying them is pointless.
pub fn classifyError(status: u16, body: []const u8) profile.ErrorClass {
    if (status == 429) {
        if (containsAny(body, &.{ "usage limit", "balance", "insufficient", "quota", "额度", "余额" })) return .quota_exceeded;
        if (containsAny(body, &.{"overloaded"})) return .transient_overload;
        return .rate_limited;
    }
    // A Console key has no refresh: "may have expired" is as final as invalid.
    if (status == 401) return .auth_invalid;
    if (status == 403) return .permission_denied;
    if (status == 404) return .wrong_endpoint;
    if (status == 400 or status == 422) {
        if (containsAny(body, &.{"model id does not exist"})) return .wrong_endpoint;
        return .bad_request;
    }
    if (status >= 500 and status <= 599) return .transient_overload;
    return .unknown;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("kimi-code"),
    .implementation_id = Slug.lit("kimi-code"),
    .display_name = "Kimi Code",
    .aliases = &.{"kimi-coding-plan"},
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("cn-responses"),
    .api_key_setup = KEY_SETUP,
    .classify_error = classifyError,
};

// ── tests ────────────────────────────────────────────────────────────────────

const credential = @import("../credential.zig");

fn channelById(comptime id: []const u8) profile.ChannelDescriptor {
    return PROFILE.channel(Slug.lit(id)).?;
}

test "kimi-code profile is structurally valid" {
    try profile.validateProfile(PROFILE);
}

test "kimi-code: every channel builds its wire's endpoint on the subscription base URL" {
    var buffer: [256]u8 = undefined;
    const cases = [_]struct {
        channel: []const u8,
        protocol: profile.Protocol,
        expected: []const u8,
    }{
        .{ .channel = "cn-responses", .protocol = .openai_responses, .expected = "https://api.kimi.com/coding/v1/responses" },
        .{ .channel = "cn-chat", .protocol = .openai_chat, .expected = "https://api.kimi.com/coding/v1/chat/completions" },
        .{ .channel = "global-responses", .protocol = .openai_responses, .expected = "https://api.kimi.ai/coding/v1/responses" },
        .{ .channel = "global-chat", .protocol = .openai_chat, .expected = "https://api.kimi.ai/coding/v1/chat/completions" },
    };
    inline for (cases) |case| {
        const descriptor = channelById(case.channel);
        try std.testing.expectEqual(@as(usize, 1), descriptor.routes.len);
        const url = try descriptor.endpointFor(PROFILE.endpoint_policy, case.protocol, null, &buffer);
        try std.testing.expectEqualStrings(case.expected, url);
        try std.testing.expectEqual(profile.Vendor.kimi, descriptor.routes[0].dialect.?);
    }
    // Responses on the China host is where a bare `--provider kimi-code` lands.
    const default = PROFILE.defaultChannel().?;
    try std.testing.expect(default.id.eqlText("cn-responses"));
    try std.testing.expect(default.routes[0].protocol.eql(.openai_responses));
}

test "kimi-code: an override can never reach the Moonshot open platform" {
    var buffer: [256]u8 = undefined;
    const responses = channelById("cn-responses");
    for ([_][]const u8{
        "https://api.moonshot.cn/v1",
        "https://api.moonshot.ai/v1",
        "https://api.moonshot.cn/anthropic",
        // The Anthropic-compatible surface of the subscription is not this wire.
        "https://api.kimi.com/coding",
    }) |url| {
        try std.testing.expectError(error.MissingRequiredEndpointPath, responses.endpointFor(PROFILE.endpoint_policy, .openai_responses, url, &buffer));
        try std.testing.expectError(error.MissingRequiredEndpointPath, channelById("cn-chat").endpointFor(PROFILE.endpoint_policy, .openai_chat, url, &buffer));
    }
    // A relay or a local mock that keeps the path contract is accepted.
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9123/coding/v1/responses",
        try responses.endpointFor(PROFILE.endpoint_policy, .openai_responses, "http://127.0.0.1:9123/coding/v1", &buffer),
    );
}

test "kimi-code: its own credential kind, KIMI_CODE_API_KEY canonical, KIMI_API_KEY accepted" {
    try std.testing.expectEqual(@as(usize, 1), PROFILE.accepted_credential_kinds.len);
    try std.testing.expectEqual(profile.CredentialKind.kimi_code_api_key, PROFILE.accepted_credential_kinds[0]);
    try std.testing.expect(!profile.CredentialKind.kimi_code_api_key.isOAuth());
    try std.testing.expectEqualStrings("KIMI_CODE_API_KEY", PROFILE.canonicalEnvAlias(.kimi_code_api_key).?);
    var accepts_kimi_api_key = false;
    for (PROFILE.env_aliases) |alias| {
        try std.testing.expectEqual(profile.CredentialKind.kimi_code_api_key, alias.kind);
        if (std.mem.eql(u8, alias.name, "KIMI_API_KEY")) accepts_kimi_api_key = true;
        // The open platform's variable never authenticates the subscription.
        try std.testing.expect(!std.mem.eql(u8, alias.name, "MOONSHOT_API_KEY"));
    }
    try std.testing.expect(accepts_kimi_api_key);
}

const TestEnv = struct {
    pairs: []const [2][]const u8,

    fn lookup(self: *TestEnv) credential.EnvLookup {
        const Impl = struct {
            fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
                const env: *TestEnv = @ptrCast(@alignCast(ctx));
                for (env.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
                return null;
            }
        };
        return .{ .ctx = @ptrCast(self), .getFn = Impl.get };
    }
};

fn resolveFor(subject: profile.ProviderProfile, env: *TestEnv, buffer: []u8) credential.ResolveError!credential.Resolved {
    return credential.resolve(.{
        .provider_id = subject.id,
        .accepted_kinds = subject.accepted_credential_kinds,
        .env_aliases = subject.env_aliases,
        .env = env.lookup(),
    }, buffer);
}

test "kimi-code: KIMI_API_KEY is the subscription's, never the open platform's" {
    const platform = @import("kimi.zig").PROFILE;
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    var subscription_only = TestEnv{ .pairs = &.{.{ "KIMI_API_KEY", "sk-kimi-sub" }} };
    const resolved = try resolveFor(PROFILE, &subscription_only, &buffer);
    try std.testing.expectEqualStrings("sk-kimi-sub", resolved.secret);
    try std.testing.expectEqualStrings("KIMI_API_KEY", resolved.alias_used.?);
    try std.testing.expectEqual(profile.CredentialKind.kimi_code_api_key, resolved.ref.kind);
    try std.testing.expectError(error.MissingCredentials, resolveFor(platform, &subscription_only, &buffer));

    // And the other way: a platform key never reaches the subscription.
    var platform_only = TestEnv{ .pairs = &.{.{ "MOONSHOT_API_KEY", "sk-platform" }} };
    try std.testing.expectError(error.MissingCredentials, resolveFor(PROFILE, &platform_only, &buffer));
    try std.testing.expectEqualStrings("sk-platform", (try resolveFor(platform, &platform_only, &buffer)).secret);

    // Both subscription names with different values is an ambiguity, not a pick.
    var both = TestEnv{ .pairs = &.{ .{ "KIMI_CODE_API_KEY", "one" }, .{ "KIMI_API_KEY", "two" } } };
    try std.testing.expectError(error.AmbiguousCredentialAliases, resolveFor(PROFILE, &both, &buffer));
}

test "kimi-code: the key pages are the Console, checked on each host's model list" {
    const setup = PROFILE.api_key_setup.?;
    try std.testing.expectEqual(profile.CredentialKind.kimi_code_api_key, setup.kind);
    try std.testing.expectEqual(@as(usize, 2), setup.pages.len);
    for (setup.pages) |page| {
        try std.testing.expectEqualStrings(CONSOLE_URL, page.url);
        try std.testing.expect(std.mem.endsWith(u8, page.check_url.?, CODING_FRAGMENT ++ "/models"));
        try std.testing.expect(std.mem.indexOf(u8, page.check_url.?, "moonshot") == null);
    }
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1/models", PROFILE.keyPage("cn").?.check_url.?);
    try std.testing.expectEqualStrings("https://api.kimi.ai/coding/v1/models", PROFILE.keyPage("global").?.check_url.?);
    // The page offered first follows the channel's host.
    try std.testing.expectEqualStrings("cn", PROFILE.defaultKeyPage(null).?.id.slice());
    try std.testing.expectEqualStrings("cn", PROFILE.defaultKeyPage(Slug.lit("cn-chat")).?.id.slice());
    try std.testing.expectEqualStrings("global", PROFILE.defaultKeyPage(Slug.lit("global-responses")).?.id.slice());
}

test "kimi-code: the six documented models, their windows and effort levels" {
    const Expect = struct { id: []const u8, window: u32, levels: bool };
    const expected = [_]Expect{
        .{ .id = "k3.1-pro", .window = 262_144, .levels = true },
        .{ .id = "k3.1-pro-highspeed", .window = 1_048_576, .levels = true },
        .{ .id = "k3", .window = 262_144, .levels = true },
        .{ .id = "k3-256k", .window = 262_144, .levels = true },
        .{ .id = "kimi-for-coding", .window = 1_048_576, .levels = true },
        .{ .id = "kimi-for-coding-highspeed", .window = 262_144, .levels = false },
    };
    try std.testing.expectEqual(expected.len, MODELS.len);
    for (expected, MODELS) |want, entry| {
        try std.testing.expectEqualStrings(want.id, entry.request_model_id);
        try std.testing.expectEqual(@as(?u32, want.window), entry.limits.context_window);
        // Undocumented, so undeclared.
        try std.testing.expectEqual(@as(?u32, null), entry.limits.max_output_tokens);
        try std.testing.expect(entry.servesProtocol(.openai_responses));
        try std.testing.expect(entry.servesProtocol(.openai_chat));
        if (controls.findSpec(entry.controls, "reasoning_effort")) |spec| {
            try std.testing.expect(want.levels);
            try std.testing.expectEqual(@as(usize, 3), spec.allowed_values.len);
            for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
        } else try std.testing.expect(!want.levels);
        // Quotes stay unknown: the membership is not billed per token.
        try std.testing.expect(!entry.quote.isKnown());
    }
    try std.testing.expect(PROFILE.quote_hook == null);
}

test "kimi-code: errors retry only when the reference calls them transient" {
    const cases = [_]struct { status: u16, body: []const u8, class: profile.ErrorClass }{
        .{ .status = 401, .body = "The API Key appears to be invalid or may have expired.", .class = .auth_invalid },
        .{ .status = 403, .body = "Your current plan supports only k3.1-pro up to 256K context.", .class = .permission_denied },
        .{ .status = 429, .body = "You've reached your 5-hour usage limit.", .class = .quota_exceeded },
        .{ .status = 429, .body = "You've reached your monthly usage limit for this billing cycle.", .class = .quota_exceeded },
        .{ .status = 429, .body = "Your credit balance is insufficient.", .class = .quota_exceeded },
        .{ .status = 429, .body = "We're receiving too many requests at the moment.", .class = .rate_limited },
        .{ .status = 429, .body = "You've reached your concurrent request limit.", .class = .rate_limited },
        .{ .status = 429, .body = "The engine is currently overloaded, please try again later", .class = .transient_overload },
        .{ .status = 400, .body = "Your model id does not exist, recognized as other: k3.1", .class = .wrong_endpoint },
        .{ .status = 400, .body = "K3.1 Pro does not support disabled thinking mode.", .class = .bad_request },
        .{ .status = 404, .body = "method not found", .class = .wrong_endpoint },
        .{ .status = 503, .body = "unavailable: 503 Service Unavailable", .class = .transient_overload },
    };
    for (cases) |case| {
        const class = classifyError(case.status, case.body);
        try std.testing.expectEqual(case.class, class);
        const retryable = case.class == .rate_limited or case.class == .transient_overload;
        try std.testing.expectEqual(retryable, class.isRetryableTransport());
    }
}
