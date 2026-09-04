//! `ProviderProfile` and `ChannelDescriptor` — the declarative provider
//! extension point (issue #16, delivery slice P0).
//!
//! The rule this module exists to enforce: adding a vendor, region, plan, or
//! account is *data*, not another branch in `main.zig`, `app.zig`, or the
//! client factory. A profile declares identity, channels, protocols, accepted
//! credential kinds, environment aliases, endpoint policy, and its own error
//! classification; the registry and factory consume profiles uniformly.
//!
//! Layering (mirrors the existing `Provider` / `Dialect` split):
//!
//! ```text
//! ProviderProfile   vendor identity, auth kinds, channels, quote/retry hooks
//! Protocol          normalized wire family (already implemented by the clients)
//! Dialect           per-vendor quirks inside one wire family (api/dialect.zig)
//! ```

const std = @import("std");
const ids = @import("ids.zig");
const offer_mod = @import("offer.zig");
const credential = @import("credential.zig");
const controls_mod = @import("controls.zig");

pub const Slug = ids.Slug;
pub const EffectiveLimits = offer_mod.EffectiveLimits;
pub const CapabilityMatrix = offer_mod.CapabilityMatrix;
pub const Quote = offer_mod.Quote;
pub const Usage = offer_mod.Usage;
pub const Availability = offer_mod.Availability;
pub const ControlSpec = controls_mod.ControlSpec;
pub const AuthScheme = credential.AuthScheme;
pub const CredentialKind = credential.CredentialKind;
pub const EnvAlias = credential.EnvAlias;

// ── protocols ────────────────────────────────────────────────────────────────

/// How a transport consumes the channel's URL. The two shapes are a real
/// difference in the existing clients: the Anthropic/OpenAI transports take a
/// complete request URL, while the Gemini transport takes an origin and
/// appends `/v1beta/models/{model}:streamGenerateContent` itself. Declaring the
/// shape keeps endpoint construction honest instead of guessing per vendor.
pub const EndpointShape = enum { absolute_request_url, base_origin };

/// Wire protocol family. `custom` is open by design — the requirement calls for
/// "or future protocol ids" — but a custom protocol must declare its own path
/// and shape, so it can never silently inherit another family's contract.
pub const Protocol = union(enum) {
    anthropic_messages,
    openai_chat,
    openai_responses,
    gemini_generate_content,
    custom: Custom,

    pub const Custom = struct {
        id: []const u8,
        path_suffix: []const u8,
        shape: EndpointShape = .absolute_request_url,
        /// The built-in wire this declarative protocol speaks.
        ///
        /// A relay that serves the OpenAI wire under a different path is a
        /// *path* difference, not a new protocol, and saying so keeps it inside
        /// the declarative schema — no adapter, no code. Null means a genuinely
        /// novel wire format, which has no transport until a reviewed adapter
        /// is registered (P2); that case still fails closed.
        wire: ?Wire = null,
    };

    /// The four wire formats a transport exists for.
    pub const Wire = enum {
        anthropic_messages,
        openai_chat,
        openai_responses,
        gemini_generate_content,

        pub fn parse(text: []const u8) ?Wire {
            inline for (@typeInfo(Wire).@"enum".fields) |field| {
                if (std.mem.eql(u8, text, field.name)) return @field(Wire, field.name);
            }
            return null;
        }
    };

    /// The wire this protocol speaks, if any transport can serve it.
    pub fn wire(self: Protocol) ?Wire {
        return switch (self) {
            .anthropic_messages => .anthropic_messages,
            .openai_chat => .openai_chat,
            .openai_responses => .openai_responses,
            .gemini_generate_content => .gemini_generate_content,
            .custom => |value| value.wire,
        };
    }

    pub fn id(self: Protocol) []const u8 {
        return switch (self) {
            .custom => |value| value.id,
            else => @tagName(self),
        };
    }

    pub fn pathSuffix(self: Protocol) []const u8 {
        return switch (self) {
            .anthropic_messages => "/v1/messages",
            .openai_chat => "/chat/completions",
            .openai_responses => "/responses",
            .gemini_generate_content => "",
            .custom => |value| value.path_suffix,
        };
    }

    pub fn shape(self: Protocol) EndpointShape {
        return switch (self) {
            .gemini_generate_content => .base_origin,
            .custom => |value| value.shape,
            else => .absolute_request_url,
        };
    }

    pub fn eql(self: Protocol, other: Protocol) bool {
        return std.mem.eql(u8, self.id(), other.id());
    }

    pub fn parse(text: []const u8) ?Protocol {
        if (std.mem.eql(u8, text, "anthropic_messages")) return .anthropic_messages;
        if (std.mem.eql(u8, text, "openai_chat")) return .openai_chat;
        if (std.mem.eql(u8, text, "openai_responses")) return .openai_responses;
        if (std.mem.eql(u8, text, "gemini_generate_content")) return .gemini_generate_content;
        return null;
    }
};

// ── endpoint policy ──────────────────────────────────────────────────────────

pub const EndpointError = error{
    InsecureEndpoint,
    ForbiddenEndpointPath,
    MissingRequiredEndpointPath,
    /// The host or path carries percent escapes. An endpoint base is a literal
    /// path; escapes only serve to hide a forbidden fragment from a substring
    /// check while the server still resolves it.
    EncodedEndpointComponent,
    /// The URL embeds userinfo. Credentials travel as a `CredentialRef`, never
    /// inside an endpoint: an endpoint string reaches offer metadata, the
    /// control-plane API, logs, and events, none of which redact it.
    CredentialInEndpoint,
    HostNotAllowed,
    MalformedEndpoint,
    EndpointBufferTooSmall,
    ProtocolNotSupportedByChannel,
};

/// Constraints an explicit `base_url` override must satisfy.
///
/// This is what stops the Coding Plan profile from silently degrading to the
/// general `/api/paas/v4` surface: the override still has to describe the plan
/// endpoint, or it is rejected before any request is built.
pub const EndpointPolicy = struct {
    require_tls: bool = true,
    /// Plaintext loopback stays available so mock-transport tests and local
    /// relays work without weakening the rule for real hosts.
    allow_loopback_plaintext: bool = true,
    forbidden_path_fragments: []const []const u8 = &.{},
    required_path_fragments: []const []const u8 = &.{},
    /// Empty means "any host that satisfies the remaining rules".
    allowed_hosts: []const []const u8 = &.{},

    pub fn validate(self: EndpointPolicy, url: []const u8) EndpointError!void {
        const uri = std.Uri.parse(url) catch return error.MalformedEndpoint;
        const host_component = uri.host orelse return error.MalformedEndpoint;
        var host_buffer: [256]u8 = undefined;
        const host = try literalComponent(host_component, &host_buffer);
        if (host.len == 0) return error.MalformedEndpoint;

        // A `user:password@host` endpoint would put a secret into
        // `ModelOffer.endpoint_ref`, and from there into `model.list`, event
        // payloads, and setup output. Refuse it at the boundary instead of
        // trying to redact it at every consumer.
        if (uri.user != null or uri.password != null) return error.CredentialInEndpoint;

        const is_tls = std.mem.eql(u8, uri.scheme, "https");
        if (!is_tls) {
            if (!std.mem.eql(u8, uri.scheme, "http")) return error.MalformedEndpoint;
            if (self.require_tls and !(self.allow_loopback_plaintext and isLoopback(host)))
                return error.InsecureEndpoint;
        }

        if (self.allowed_hosts.len > 0) {
            var matched = false;
            for (self.allowed_hosts) |allowed| {
                if (std.ascii.eqlIgnoreCase(allowed, host)) matched = true;
            }
            if (!matched) return error.HostNotAllowed;
        }

        var path_buffer: [1024]u8 = undefined;
        const path = try literalComponent(uri.path, &path_buffer);
        for (self.forbidden_path_fragments) |fragment| {
            if (std.mem.indexOf(u8, path, fragment) != null) return error.ForbiddenEndpointPath;
        }
        for (self.required_path_fragments) |fragment| {
            if (std.mem.indexOf(u8, path, fragment) == null) return error.MissingRequiredEndpointPath;
        }
    }

    /// Both the profile-level and route-level policies must pass. Neither can
    /// relax the other; an override has to satisfy the intersection.
    pub fn validateBoth(
        profile_policy: EndpointPolicy,
        route_policy: EndpointPolicy,
        url: []const u8,
    ) EndpointError!void {
        try profile_policy.validate(url);
        try route_policy.validate(url);
    }
};

/// A URI component that must be literal.
///
/// Substring policy on a percent-encoded component is not a check at all:
/// `https://open.bigmodel.cn/api%2Fpaas%2Fv4` does not contain the literal
/// `/api/paas/v4`, yet a server that decodes the path routes it there. Rather
/// than guess which side decodes, reject any escape in an endpoint base — a
/// provider endpoint has no legitimate need for one — and run the policy on
/// bytes that are identical on the wire and in the check.
fn literalComponent(component: std.Uri.Component, buffer: []u8) EndpointError![]const u8 {
    const text = component.toRaw(buffer) catch return error.MalformedEndpoint;
    const encoded = switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, text, encoded)) return error.EncodedEndpointComponent;
    if (std.mem.indexOfScalar(u8, text, '%') != null) return error.EncodedEndpointComponent;
    return text;
}

fn isLoopback(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

// ── channels and inventory ───────────────────────────────────────────────────

pub const ProtocolRoute = struct {
    protocol: Protocol,
    /// Overrides the protocol default for channels with a nonstandard path.
    path_suffix: ?[]const u8 = null,
    policy: EndpointPolicy = .{},

    pub fn suffix(self: ProtocolRoute) []const u8 {
        return self.path_suffix orelse self.protocol.pathSuffix();
    }
};

/// A model this profile serves, as declared by the profile (not guessed from
/// the model name). Channel-level narrowing is applied on top when the catalog
/// materializes offers.
pub const ModelEntry = struct {
    request_model_id: []const u8,
    display_name: []const u8,
    canonical_model_id: ?[]const u8 = null,
    upstream_model_id: ?[]const u8 = null,
    model_variant: ?[]const u8 = null,
    limits: EffectiveLimits = .{},
    capabilities: CapabilityMatrix = .{},
    quote: Quote = .unknown,
    availability: Availability = .available,
    /// Controls this model accepts. Provider-declared; the kernel adds none.
    controls: []const ControlSpec = &.{},
    /// Protocol subset this model is reachable through. Empty = every route the
    /// channel exposes.
    protocols: []const Protocol = &.{},

    pub fn servesProtocol(self: ModelEntry, protocol: Protocol) bool {
        if (self.protocols.len == 0) return true;
        for (self.protocols) |candidate| if (candidate.eql(protocol)) return true;
        return false;
    }
};

/// One endpoint/deployment/region/plan/account binding.
///
/// A channel may expose several protocols; protocol-specific constraints stay
/// on the route, and the resulting offers stay distinct per protocol.
pub const ChannelDescriptor = struct {
    id: Slug,
    display_name: []const u8,
    /// Origin plus any version prefix, without a trailing slash.
    base_url: []const u8,
    routes: []const ProtocolRoute,
    region: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    account: ?[]const u8 = null,
    /// Channel inventory. Empty = inherit the profile-level inventory.
    models: []const ModelEntry = &.{},
    /// Channel-level narrowing applied over each model's own metadata.
    limits: EffectiveLimits = .{},
    capabilities: CapabilityMatrix = .{},
    quote: Quote = .unknown,
    /// Channel-specific control declaration. Non-empty replaces the model's
    /// own list: a channel can genuinely offer a different control surface.
    controls: []const ControlSpec = &.{},

    pub fn route(self: ChannelDescriptor, protocol: Protocol) ?ProtocolRoute {
        for (self.routes) |candidate| if (candidate.protocol.eql(protocol)) return candidate;
        return null;
    }

    /// Build the URL the transport receives for this protocol.
    ///
    /// `override` replaces the channel base only after it satisfies both the
    /// profile and route endpoint policies — the check happens here so no code
    /// path can construct a request URL that skipped validation.
    pub fn endpointFor(
        self: ChannelDescriptor,
        profile_policy: EndpointPolicy,
        protocol: Protocol,
        override: ?[]const u8,
        buffer: []u8,
    ) EndpointError![]const u8 {
        const selected = self.route(protocol) orelse return error.ProtocolNotSupportedByChannel;
        const base_raw = override orelse self.base_url;
        if (override != null)
            try EndpointPolicy.validateBoth(profile_policy, selected.policy, base_raw);
        const base = std.mem.trimEnd(u8, base_raw, "/");
        const suffix = switch (protocol.shape()) {
            .base_origin => "",
            .absolute_request_url => selected.suffix(),
        };
        if (base.len + suffix.len > buffer.len) return error.EndpointBufferTooSmall;
        @memcpy(buffer[0..base.len], base);
        @memcpy(buffer[base.len..][0..suffix.len], suffix);
        return buffer[0 .. base.len + suffix.len];
    }
};

// ── provider-owned hooks ─────────────────────────────────────────────────────

/// Provider-owned error classification. The kernel decides *policy* (what may
/// be retried); the provider decides *facts* (what this status/body means).
pub const ErrorClass = enum {
    unknown,
    transient_overload,
    rate_limited,
    /// Provider confirmed the access token expired before processing.
    auth_expired,
    auth_invalid,
    quota_exceeded,
    permission_denied,
    bad_request,
    /// The request reached a real host but the wrong API surface.
    wrong_endpoint,
    transport,

    /// Only genuine capacity problems are retried as transport failures.
    /// Invalid key, wrong endpoint, quota, and permission errors must not be.
    pub fn isRetryableTransport(self: ErrorClass) bool {
        return switch (self) {
            .transient_overload, .rate_limited, .transport => true,
            .unknown, .auth_expired, .auth_invalid, .quota_exceeded, .permission_denied, .bad_request, .wrong_endpoint => false,
        };
    }

    /// A single replay is allowed only for a provider-confirmed auth expiry
    /// observed before request processing, and only for a replayable body.
    pub fn allowsSingleAuthReplay(self: ErrorClass) bool {
        return self == .auth_expired;
    }
};

pub const ClassifyFn = *const fn (status: u16, body: []const u8) ErrorClass;

/// Provider-owned pricing. Receives normalized usage plus the resolved route
/// identity and returns a quote or `unknown` — never a fabricated zero.
pub const QuoteFn = *const fn (
    request_model_id: []const u8,
    channel_id: Slug,
    usage: Usage,
) Quote;

/// Default classification shared by profiles without a vendor-specific hook.
/// Deliberately conservative: an unrecognized status is `unknown`, which is
/// not retryable.
pub fn defaultClassifyError(status: u16, body: []const u8) ErrorClass {
    _ = body;
    return switch (status) {
        401 => .auth_expired,
        403 => .permission_denied,
        404 => .wrong_endpoint,
        429 => .rate_limited,
        400, 422 => .bad_request,
        500, 502, 503, 504, 529 => .transient_overload,
        else => .unknown,
    };
}

// ── the profile ──────────────────────────────────────────────────────────────

pub const ProviderProfile = struct {
    /// Configured instance identity. Two instances may share one
    /// implementation while keeping distinct credentials and channels.
    id: Slug,
    /// Registry implementation key, e.g. `openai` reused by `openai-work` and
    /// `openai-personal`.
    implementation_id: Slug,
    display_name: []const u8,
    /// Configuration-only names. They resolve to `id`; they are never a second
    /// identity and never appear in an offer id.
    aliases: []const []const u8 = &.{},
    channels: []const ChannelDescriptor,
    /// Inventory shared by channels that declare no models of their own.
    models: []const ModelEntry = &.{},
    accepted_credential_kinds: []const CredentialKind,
    env_aliases: []const EnvAlias = &.{},
    auth: AuthScheme = .bearer,
    default_channel: ?Slug = null,
    endpoint_policy: EndpointPolicy = .{},
    classify_error: ClassifyFn = defaultClassifyError,
    quote_hook: ?QuoteFn = null,
    /// RFC 6749 token endpoint for this provider's OAuth kinds. Null means the
    /// profile declares no OAuth lifecycle here.
    oauth_token_url: ?[]const u8 = null,
    /// RFC 6749 authorization endpoint, for the loopback-redirect PKCE login
    /// that obtains the *first* token (issue #33). Null means this profile
    /// offers no browser flow, and the only entry point is an out-of-band
    /// token response.
    oauth_authorize_url: ?[]const u8 = null,
    /// RFC 8628 device authorization endpoint. Declared separately because a
    /// headless or SSH session cannot open a browser and a loopback redirect
    /// has nowhere to land; a provider that supports neither keeps both null.
    oauth_device_authorization_url: ?[]const u8 = null,
    /// The registered OAuth client this installation presents. Both the
    /// interactive grant and the refresh grant send it, so a wrong value
    /// surfaces as `invalid_client` on the very first exchange rather than as
    /// a mysterious expiry later. Null means the profile declares none and the
    /// user must supply one.
    oauth_client_id: ?[]const u8 = null,
    /// Space-separated scopes requested at authorization time. Empty omits the
    /// parameter entirely, which is what a provider that scopes by client
    /// registration expects.
    oauth_scope: []const u8 = "",

    /// True when this profile can obtain a first token without the user
    /// producing a token response by other means.
    pub fn declaresInteractiveOAuth(self: ProviderProfile) bool {
        return self.oauth_token_url != null and
            (self.oauth_authorize_url != null or self.oauth_device_authorization_url != null);
    }

    pub fn matchesName(self: ProviderProfile, name: []const u8) bool {
        if (self.id.eqlText(name)) return true;
        for (self.aliases) |alias| if (std.mem.eql(u8, alias, name)) return true;
        return false;
    }

    pub fn channel(self: ProviderProfile, id: Slug) ?ChannelDescriptor {
        for (self.channels) |candidate| if (candidate.id.eql(id)) return candidate;
        return null;
    }

    pub fn defaultChannel(self: ProviderProfile) ?ChannelDescriptor {
        if (self.default_channel) |id| return self.channel(id);
        if (self.channels.len > 0) return self.channels[0];
        return null;
    }

    pub fn inventoryFor(self: ProviderProfile, descriptor: ChannelDescriptor) []const ModelEntry {
        return if (descriptor.models.len > 0) descriptor.models else self.models;
    }

    pub fn canonicalEnvAlias(self: ProviderProfile, kind: CredentialKind) ?[]const u8 {
        for (self.env_aliases) |alias| {
            if (alias.kind == kind and alias.canonical) return alias.name;
        }
        for (self.env_aliases) |alias| {
            if (alias.kind == kind) return alias.name;
        }
        return null;
    }

    pub fn quote(self: ProviderProfile, request_model_id: []const u8, channel_id: Slug, usage: Usage) Quote {
        const hook = self.quote_hook orelse return .unknown;
        return hook(request_model_id, channel_id, usage);
    }
};

/// Structural validation performed before a profile is admitted to the
/// registry. Catching these at registration keeps every downstream consumer
/// free of "can this even be routed?" defensive code.
pub const ProfileError = error{
    NoChannels,
    NoRoutes,
    DuplicateChannelId,
    DuplicateProtocolRoute,
    UnknownDefaultChannel,
    NoCredentialKinds,
    EnvAliasKindNotAccepted,
    NoModelInventory,
    InvalidChannelBaseUrl,
};

pub fn validateProfile(profile: ProviderProfile) ProfileError!void {
    if (profile.channels.len == 0) return error.NoChannels;
    if (profile.accepted_credential_kinds.len == 0) return error.NoCredentialKinds;

    for (profile.env_aliases) |alias| {
        var accepted = false;
        for (profile.accepted_credential_kinds) |kind| {
            if (kind == alias.kind) accepted = true;
        }
        if (!accepted) return error.EnvAliasKindNotAccepted;
    }

    for (profile.channels, 0..) |descriptor, index| {
        if (descriptor.routes.len == 0) return error.NoRoutes;
        for (profile.channels[index + 1 ..]) |other| {
            if (descriptor.id.eql(other.id)) return error.DuplicateChannelId;
        }
        for (descriptor.routes, 0..) |current, route_index| {
            for (descriptor.routes[route_index + 1 ..]) |other| {
                if (current.protocol.eql(other.protocol)) return error.DuplicateProtocolRoute;
            }
        }
        // The declared base must satisfy the profile policy *and* every route
        // policy on this channel. Validating only the profile level would let a
        // profile ship a base its own overrides would be rejected for — the
        // declaration and the enforcement would disagree.
        for (descriptor.routes) |route| {
            EndpointPolicy.validateBoth(
                profile.endpoint_policy,
                route.policy,
                descriptor.base_url,
            ) catch return error.InvalidChannelBaseUrl;
        }
        if (profile.inventoryFor(descriptor).len == 0) return error.NoModelInventory;
    }

    if (profile.default_channel) |id| {
        if (profile.channel(id) == null) return error.UnknownDefaultChannel;
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const TEST_MODELS = [_]ModelEntry{.{ .request_model_id = "m", .display_name = "M" }};

fn testProfile(channels: []const ChannelDescriptor, policy: EndpointPolicy) ProviderProfile {
    return .{
        .id = Slug.lit("test"),
        .implementation_id = Slug.lit("test"),
        .display_name = "Test",
        .channels = channels,
        .models = &TEST_MODELS,
        .accepted_credential_kinds = &.{.api_key},
        .endpoint_policy = policy,
    };
}

test "endpoint construction appends the protocol path to the channel base" {
    const routes = [_]ProtocolRoute{
        .{ .protocol = .openai_chat },
        .{ .protocol = .anthropic_messages },
    };
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("cn"),
        .display_name = "China",
        .base_url = "https://open.bigmodel.cn/api/coding/paas/v4",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{});
    var buffer: [256]u8 = undefined;
    const url = try channels[0].endpointFor(profile.endpoint_policy, .openai_chat, null, &buffer);
    try std.testing.expectEqualStrings(
        "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions",
        url,
    );
}

test "base-origin protocols receive the origin unchanged" {
    const routes = [_]ProtocolRoute{.{ .protocol = .gemini_generate_content }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("default"),
        .display_name = "Default",
        .base_url = "https://generativelanguage.googleapis.com/",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{});
    var buffer: [256]u8 = undefined;
    const url = try channels[0].endpointFor(profile.endpoint_policy, .gemini_generate_content, null, &buffer);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com", url);
}

test "a protocol the channel does not route is rejected, not defaulted" {
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("default"),
        .display_name = "Default",
        .base_url = "https://example.test/v1",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{});
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(
        error.ProtocolNotSupportedByChannel,
        channels[0].endpointFor(profile.endpoint_policy, .anthropic_messages, null, &buffer),
    );
}

test "endpoint policy rejects a forbidden fallback surface in an override" {
    const forbidden = [_][]const u8{"/api/paas/v4"};
    const required = [_][]const u8{"/coding/"};
    const routes = [_]ProtocolRoute{.{
        .protocol = .openai_chat,
        .policy = .{ .required_path_fragments = &required },
    }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("cn-openai"),
        .display_name = "China",
        .base_url = "https://open.bigmodel.cn/api/coding/paas/v4",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{ .forbidden_path_fragments = &forbidden });
    var buffer: [256]u8 = undefined;

    try std.testing.expectError(error.ForbiddenEndpointPath, channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "https://open.bigmodel.cn/api/paas/v4",
        &buffer,
    ));
    try std.testing.expectError(error.MissingRequiredEndpointPath, channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "https://open.bigmodel.cn/api/other/v4",
        &buffer,
    ));
    const accepted = try channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "https://proxy.internal/api/coding/paas/v4",
        &buffer,
    );
    try std.testing.expectEqualStrings("https://proxy.internal/api/coding/paas/v4/chat/completions", accepted);
}

test "endpoint policy requires TLS except on loopback" {
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("default"),
        .display_name = "Default",
        .base_url = "https://example.test/v1",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{});
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(error.InsecureEndpoint, channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "http://public.example/v1",
        &buffer,
    ));
    const loopback = try channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "http://127.0.0.1:8123/v1",
        &buffer,
    );
    try std.testing.expectEqualStrings("http://127.0.0.1:8123/v1/chat/completions", loopback);
}

test "endpoint policy can pin allowed hosts" {
    const hosts = [_][]const u8{"api.z.ai"};
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("global"),
        .display_name = "Global",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{ .allowed_hosts = &hosts });
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(error.HostNotAllowed, channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "https://evil.test/api/coding/paas/v4",
        &buffer,
    ));
}

test "profile validation rejects structurally impossible profiles" {
    const routes = [_]ProtocolRoute{ .{ .protocol = .openai_chat }, .{ .protocol = .openai_chat } };
    const dup_routes = [_]ChannelDescriptor{.{
        .id = Slug.lit("a"),
        .display_name = "A",
        .base_url = "https://example.test/v1",
        .routes = &routes,
    }};
    try std.testing.expectError(error.DuplicateProtocolRoute, validateProfile(testProfile(&dup_routes, .{})));

    const one_route = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const dup_channels = [_]ChannelDescriptor{
        .{ .id = Slug.lit("a"), .display_name = "A", .base_url = "https://example.test/v1", .routes = &one_route },
        .{ .id = Slug.lit("a"), .display_name = "A2", .base_url = "https://example.test/v2", .routes = &one_route },
    };
    try std.testing.expectError(error.DuplicateChannelId, validateProfile(testProfile(&dup_channels, .{})));

    var no_models = testProfile(dup_channels[0..1], .{});
    no_models.models = &.{};
    try std.testing.expectError(error.NoModelInventory, validateProfile(no_models));

    var bad_default = testProfile(dup_channels[0..1], .{});
    bad_default.default_channel = Slug.lit("missing");
    try std.testing.expectError(error.UnknownDefaultChannel, validateProfile(bad_default));

    var stray_alias = testProfile(dup_channels[0..1], .{});
    const aliases = [_]EnvAlias{.{ .name = "X", .kind = .metask_oauth }};
    stray_alias.env_aliases = &aliases;
    try std.testing.expectError(error.EnvAliasKindNotAccepted, validateProfile(stray_alias));
}

test "error classes separate capacity problems from auth and quota" {
    try std.testing.expect(ErrorClass.transient_overload.isRetryableTransport());
    try std.testing.expect(ErrorClass.rate_limited.isRetryableTransport());
    try std.testing.expect(!ErrorClass.auth_invalid.isRetryableTransport());
    try std.testing.expect(!ErrorClass.quota_exceeded.isRetryableTransport());
    try std.testing.expect(!ErrorClass.permission_denied.isRetryableTransport());
    try std.testing.expect(!ErrorClass.wrong_endpoint.isRetryableTransport());
    try std.testing.expect(!ErrorClass.unknown.isRetryableTransport());
    try std.testing.expect(ErrorClass.auth_expired.allowsSingleAuthReplay());
    try std.testing.expect(!ErrorClass.auth_invalid.allowsSingleAuthReplay());
}

test "protocol ids and path suffixes are explicit, never inferred" {
    try std.testing.expectEqualStrings("openai_chat", (Protocol{ .openai_chat = {} }).id());
    try std.testing.expectEqualStrings("/v1/messages", (Protocol{ .anthropic_messages = {} }).pathSuffix());
    try std.testing.expectEqualStrings("/responses", (Protocol{ .openai_responses = {} }).pathSuffix());
    try std.testing.expectEqual(EndpointShape.base_origin, (Protocol{ .gemini_generate_content = {} }).shape());
    const custom = Protocol{ .custom = .{ .id = "vendor_v2", .path_suffix = "/v2/generate" } };
    try std.testing.expectEqualStrings("vendor_v2", custom.id());
    try std.testing.expect(!custom.eql(.openai_chat));
    try std.testing.expect(Protocol.parse("vendor_v2") == null);
}

test "aliases resolve to the profile id without becoming a second identity" {
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("cn-openai"),
        .display_name = "China",
        .base_url = "https://example.test/v1",
        .routes = &routes,
    }};
    var profile = testProfile(&channels, .{});
    const aliases = [_][]const u8{"glm-coding-plan"};
    profile.aliases = &aliases;
    try std.testing.expect(profile.matchesName("test"));
    try std.testing.expect(profile.matchesName("glm-coding-plan"));
    try std.testing.expect(!profile.matchesName("glm"));
}

test "a percent-encoded path cannot smuggle a forbidden fragment past the policy" {
    const forbidden = [_][]const u8{"/api/paas/v4"};
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("cn-openai"),
        .display_name = "China",
        .base_url = "https://open.bigmodel.cn/api/coding/paas/v4",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{ .forbidden_path_fragments = &forbidden });
    var buffer: [256]u8 = undefined;

    // Encoded separators do not contain the literal fragment, but a server that
    // decodes the path routes it to exactly the forbidden surface.
    for ([_][]const u8{
        "https://open.bigmodel.cn/api%2Fpaas%2Fv4",
        "https://open.bigmodel.cn/api%2fpaas%2fv4",
        "https://open.bigmodel.cn/%61pi/paas/v4",
    }) |smuggled| {
        try std.testing.expectError(error.EncodedEndpointComponent, channels[0].endpointFor(
            profile.endpoint_policy,
            .openai_chat,
            smuggled,
            &buffer,
        ));
    }

    // An encoded host is refused for the same reason.
    try std.testing.expectError(error.EncodedEndpointComponent, channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "https://open%2Ebigmodel%2Ecn/api/coding/paas/v4",
        &buffer,
    ));
}

test "loopback detection is case insensitive" {
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("default"),
        .display_name = "Default",
        .base_url = "https://example.test/v1",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{});
    var buffer: [256]u8 = undefined;
    const url = try channels[0].endpointFor(
        profile.endpoint_policy,
        .openai_chat,
        "http://LocalHost:8123/v1",
        &buffer,
    );
    try std.testing.expectEqualStrings("http://LocalHost:8123/v1/chat/completions", url);
}

test "profile validation proves each channel base satisfies its own route policy" {
    // A channel whose declared base does not satisfy its route's required
    // fragment is a profile bug: overrides would be rejected for a URL shape
    // the profile itself ships.
    const required = [_][]const u8{"/coding/"};
    const routes = [_]ProtocolRoute{.{
        .protocol = .openai_chat,
        .policy = .{ .required_path_fragments = &required },
    }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("bad"),
        .display_name = "Bad",
        .base_url = "https://vendor.test/api/paas/v4",
        .routes = &routes,
    }};
    try std.testing.expectError(
        error.InvalidChannelBaseUrl,
        validateProfile(testProfile(&channels, .{})),
    );
}

test "an endpoint may not carry credentials in its userinfo" {
    const routes = [_]ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]ChannelDescriptor{.{
        .id = Slug.lit("relay"),
        .display_name = "Relay",
        .base_url = "https://relay.internal/v1",
        .routes = &routes,
    }};
    const profile = testProfile(&channels, .{});
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{
        "https://sk-secret-key@relay.internal/v1",
        "https://user:sk-secret@relay.internal/v1",
        "http://tok@127.0.0.1:8123/v1",
    }) |with_credential| {
        try std.testing.expectError(error.CredentialInEndpoint, channels[0].endpointFor(
            profile.endpoint_policy,
            .openai_chat,
            with_credential,
            &buffer,
        ));
    }
    // The declared bases of every built-in profile are checked the same way by
    // `validateProfile`, so a profile cannot ship one either.
}
