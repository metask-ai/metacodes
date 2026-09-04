//! Interactive provider OAuth login, shared by the CLI
//! (`metacodes login --provider <id>`) and the TUI (`/login <id>`) — issue #33.
//!
//! The decisions that used to live inline in `main.zig` — which provider,
//! whether a stored login for it would ever be consulted, whether it declares
//! the endpoint the requested grant needs, which client presents the grant —
//! are `prepare`. Each refusal is its own error, raised before anything is
//! contacted or written, so a front end can say why. `Prepared.run` is the
//! grant itself followed by the one durable import both login paths end in;
//! keeping that import single is what makes "logged in interactively" and
//! "imported a token response" indistinguishable to everything downstream.
//!
//! `run` carries an inferred error set: the grant's transport errors come out
//! of `oauth_login.acquireFirstToken` by name and are not enumerable here. The
//! import's refusals are typed (`ImportError`), with the failing step's own
//! error available through `ImportDiagnostic` for a message.

const std = @import("std");
const oauth_login = @import("oauth_login.zig");
const metask_oauth = @import("metask_oauth.zig");
const provider_host = @import("../provider/host.zig");
const provider_ids = @import("../provider/ids.zig");
const provider_oauth = @import("../provider/oauth.zig");
const provider_profile = @import("../provider/profile.zig");
const time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const Method = oauth_login.Method;

pub const Options = struct {
    method: Method = .loopback,
    open_browser: bool = true,
    /// Overrides the client the profile declares, and supplies one when the
    /// profile declares none; the refresh grant then presents it too.
    client_id: ?[]const u8 = null,
    port: u16 = oauth_login.DEFAULT_CALLBACK_PORT,
    timeout_seconds: u32 = 300,
    /// Checked between waits of the loopback flow and between polls of the device-code flow; null means the flow is bounded only by the user's browser or `timeout_seconds`.
    abort_signal: ?*const AbortSignal = null,
};

/// A stored login for this profile would never be consulted.
pub const CapabilityError = error{
    ProviderHasNoTokenEndpoint,
    /// No credential kind the profile accepts is an OAuth kind: credential
    /// resolution opens the OAuth session for those kinds and no others, so a
    /// login stored for such a profile is a success message followed by
    /// silence.
    ProviderAcceptsNoOAuthKind,
};

/// Why a login cannot start. Nothing was contacted and nothing was written.
pub const PrepareError = CapabilityError || error{
    /// The profile declares no endpoint for the requested grant.
    FlowUnavailable,
    /// Neither the profile nor the caller supplies an OAuth client id.
    ClientIdMissing,
};

pub const Error = PrepareError || error{UnknownProvider};

pub fn refusalText(err: PrepareError, method: Method) []const u8 {
    return switch (err) {
        error.ProviderHasNoTokenEndpoint => "that provider declares no OAuth token endpoint",
        error.ProviderAcceptsNoOAuthKind => "that provider accepts no OAuth credential kind; a stored login would never be consulted",
        error.FlowUnavailable => switch (method) {
            .loopback => "that provider declares no OAuth authorization endpoint",
            .device_code => "that provider declares no device authorization endpoint",
        },
        error.ClientIdMissing => "that provider declares no OAuth client id",
    };
}

/// Why the durable import refused a token response. When a step failed rather
/// than decided, its own error is in the `ImportDiagnostic`.
pub const ImportError = error{
    InvalidTokenResponse,
    MissingRefreshToken,
    MetaskGatewayMissing,
    MetaskGatewayNotOrigin,
    StoreOpenFailed,
    ClientRecordFailed,
    TokenStoreFailed,
};

pub const ImportDiagnostic = struct {
    /// The error the failing step raised; null when the import refused on a
    /// decision (a missing refresh token, a malformed Metask gateway).
    cause: ?anyerror = null,
};

pub const ClientIdSource = enum { explicit, declared };

pub const Outcome = struct {
    provider_id: provider_ids.Slug,
    /// Whether the grant presented the caller's client or the profile's.
    client_id_source: ClientIdSource,
};

/// A login that passed every refusal check. Nothing has been contacted yet.
pub const Prepared = struct {
    profile: *const provider_profile.ProviderProfile,
    client_id: []const u8,
    client_id_source: ClientIdSource,
    options: Options,

    /// Run the grant and persist the login exactly as `metacodes login
    /// --provider` does. `notify` receives the lines the user must act on —
    /// the URL to open, the code to enter. A failed import sets `diagnostic`
    /// when one is given.
    pub fn run(
        self: Prepared,
        allocator: std.mem.Allocator,
        io: std.Io,
        notify: oauth_login.Notify,
        diagnostic: ?*ImportDiagnostic,
    ) !Outcome {
        const token_json = try oauth_login.acquireFirstToken(allocator, io, .{
            // Checked by `prepare`; unwrapped here so the flow gets a plain URL.
            .token_url = self.profile.oauth_token_url.?,
            .authorize_url = self.profile.oauth_authorize_url,
            .device_authorization_url = self.profile.oauth_device_authorization_url,
            .client_id = self.client_id,
            .scope = self.profile.oauth_scope,
        }, .{
            .method = self.options.method,
            .open_browser = self.options.open_browser,
            .port = self.options.port,
            .timeout_seconds = self.options.timeout_seconds,
            .abort_signal = self.options.abort_signal,
            .notify = notify,
        });
        defer {
            std.crypto.secureZero(u8, token_json);
            allocator.free(token_json);
        }
        try importTokenResponse(allocator, self.profile.id, token_json, self.client_id, diagnostic);
        return .{ .provider_id = self.profile.id, .client_id_source = self.client_id_source };
    }
};

/// Refuse a profile whose stored login could never be used. Both login paths
/// ask this before doing anything the user would have to undo — the token-JSON
/// import before it writes, the interactive flow before it sends anyone to a
/// browser.
pub fn requireOAuthCapable(profile: *const provider_profile.ProviderProfile) CapabilityError!void {
    if (profile.oauth_token_url == null) return error.ProviderHasNoTokenEndpoint;
    for (profile.accepted_credential_kinds) |kind| {
        if (provider_oauth.servesKind(kind)) return;
    }
    return error.ProviderAcceptsNoOAuthKind;
}

/// Every decision the interactive login makes before it starts, for a profile
/// the caller already resolved.
pub fn prepareProfile(profile: *const provider_profile.ProviderProfile, options: Options) PrepareError!Prepared {
    try requireOAuthCapable(profile);
    // A profile with no authorization or device endpoint has no interactive
    // flow to run; say so instead of failing later at a null URL.
    const endpoint_declared = switch (options.method) {
        .loopback => profile.oauth_authorize_url != null,
        .device_code => profile.oauth_device_authorization_url != null,
    };
    if (!endpoint_declared) return error.FlowUnavailable;
    const client_id = options.client_id orelse profile.oauth_client_id orelse return error.ClientIdMissing;
    return .{
        .profile = profile,
        .client_id = client_id,
        .client_id_source = if (options.client_id != null) .explicit else .declared,
        .options = options,
    };
}

/// `prepareProfile` for a provider named the way the user names it.
pub fn prepare(host: *provider_host.Host, provider_name: []const u8, options: Options) Error!Prepared {
    const profile = host.registry.find(provider_name) orelse return error.UnknownProvider;
    return prepareProfile(profile, options);
}

/// `prepare` then `run`, for a caller that reports a failure by its error name.
pub fn loginInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *provider_host.Host,
    provider_name: []const u8,
    options: Options,
    notify: oauth_login.Notify,
) !Outcome {
    const prepared = try prepare(host, provider_name, options);
    return prepared.run(allocator, io, notify, null);
}

/// The one durable import both provider login paths end in.
pub fn importTokenResponse(
    allocator: std.mem.Allocator,
    provider_id: provider_ids.Slug,
    token_json: []const u8,
    client_id: ?[]const u8,
    diagnostic: ?*ImportDiagnostic,
) ImportError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const outcome = provider_oauth.parseTokenResponse(arena.allocator(), token_json) catch |err|
        return failed(diagnostic, err, error.InvalidTokenResponse);
    if (outcome.refresh_token == null) return error.MissingRefreshToken;
    if (provider_id.eqlText("metask")) {
        if (outcome.gateway_url == null or outcome.models_url == null) return error.MetaskGatewayMissing;
        if (!metask_oauth.isGatewayOrigin(outcome.gateway_url.?)) return error.MetaskGatewayNotOrigin;
    }

    var session = provider_oauth.Session.initHome(allocator, provider_id) catch |err|
        return failed(diagnostic, err, error.StoreOpenFailed);
    defer session.deinit();
    // Recorded before the import so it lands in the same atomic write as the
    // tokens: a refresh that presents a different client is rejected outright.
    // Metask's JSON refresh grant is bound to the authorization and expressly
    // omits client_id; other provider profiles retain their registered client.
    session.setClientId(if (provider_id.eqlText("metask")) null else client_id) catch |err|
        return failed(diagnostic, err, error.ClientRecordFailed);
    session.importOutcome(outcome, time.nowUnix()) catch |err|
        return failed(diagnostic, err, error.TokenStoreFailed);
}

fn failed(diagnostic: ?*ImportDiagnostic, cause: anyerror, err: ImportError) ImportError {
    if (diagnostic) |out| out.cause = cause;
    return err;
}
