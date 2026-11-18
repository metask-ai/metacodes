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
const api_key_store = @import("../provider/api_key_store.zig");
const provider_credential = @import("../provider/credential.zig");
const catalog_fetch = @import("catalog_fetch.zig");
const openrouter_login = @import("openrouter_login.zig");

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
    /// The host's state root: the login is stored under `<state_root>/oauth`
    /// (unless METACODES_OAUTH_DIR overrides it). No default: a caller that
    /// forgot it would finish the browser flow and then fail to store the
    /// login (the REPL `/login` did, before this field became required).
    state_root: []const u8,
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

/// Why `prepareFlow` refuses: a `PrepareError`, or a client id offered to a
/// provider that signs in with a client of its own (Metask), which would
/// otherwise be ignored.
pub const FlowError = PrepareError || error{ClientIdFixed};

pub const Error = PrepareError || error{UnknownProvider};

pub fn refusalText(err: FlowError, method: Method) []const u8 {
    return switch (err) {
        error.ProviderHasNoTokenEndpoint => "that provider declares no OAuth token endpoint",
        error.ProviderAcceptsNoOAuthKind => "that provider accepts no OAuth credential kind; a stored login would never be consulted",
        error.FlowUnavailable => switch (method) {
            .loopback => "that provider declares no OAuth authorization endpoint",
            .device_code => "that provider declares no device authorization endpoint",
        },
        error.ClientIdMissing => "that provider declares no OAuth client id; pass --client-id or set providers.<id>.oauth_client_id in <state root>/config.json",
        error.ClientIdFixed => "that provider signs in with its own client; drop --client-id",
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

/// Which client the grant presented, in order of precedence: the caller's
/// `--client-id`, the installation's `providers.<id>.oauth_client_id`, or the
/// profile's own declaration.
pub const ClientIdSource = enum { explicit, configured, declared };

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
        const provider_id = self.profile.id;
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
        try importTokenResponse(allocator, self.options.state_root, provider_id, token_json, self.client_id, diagnostic);
        return .{ .provider_id = provider_id, .client_id_source = self.client_id_source };
    }
};

/// Metask's sign-in (#33): its control plane runs its own JSON device grant
/// (`metask_oauth`), not RFC 8628, so it is not a `Prepared` OAuth profile.
/// The token response ends in the same `importTokenResponse` every login
/// ends in, which applies Metask's gateway rules and stores no client id.
pub const MetaskPrepared = struct {
    options: Options,

    pub fn run(
        self: MetaskPrepared,
        allocator: std.mem.Allocator,
        io: std.Io,
        notify: oauth_login.Notify,
        diagnostic: ?*ImportDiagnostic,
    ) !Outcome {
        const token_json = try metask_oauth.acquireDeviceTokenWith(
            allocator,
            io,
            metask_oauth.siteUrl(),
            self.options.open_browser,
            .{ .ctx = @ptrCast(@constCast(&notify)), .show = showDeviceCode },
            self.options.abort_signal,
        );
        defer {
            std.crypto.secureZero(u8, token_json);
            allocator.free(token_json);
        }
        const metask = provider_ids.Slug.lit("metask");
        // The session this one replaces (#560), revoked once it is stored,
        // bounded as the TUI's `/logout`.
        var replaced = metask_oauth.Replaced.capture(allocator, self.options.state_root);
        defer replaced.deinit();
        try importTokenResponse(allocator, self.options.state_root, metask, token_json, null, diagnostic);
        if (metask_oauth.replacedNote(replaced.revoke(token_json, metask_oauth.siteUrl(), 3000))) |note| {
            var line: [256]u8 = undefined;
            notify.say(std.fmt.bufPrint(&line, "{s}\n", .{note.text}) catch note.text);
        }
        return .{ .provider_id = metask, .client_id_source = .declared };
    }

    /// The device page and code, in the words the generic device flow uses.
    fn showDeviceCode(ctx: ?*anyopaque, uri: []const u8, code: []const u8) void {
        const notify: *const oauth_login.Notify = @ptrCast(@alignCast(ctx.?));
        var buffer: [1024]u8 = undefined;
        notify.say(std.fmt.bufPrint(&buffer, "Open {s} and enter the code {s}\n\n", .{ uri, code }) catch "Open the Metask device page and enter the code it asks for.\n");
    }
};

/// Longest API key a login accepts from a paste or a prompt.
pub const MAX_KEY_LEN = 512;

/// Why a pasted key was not stored.
pub const KeyError = error{
    /// The provider answered the check with 401/403.
    KeyRefused,
    /// The check could not be made (network, an unexpected status); nothing
    /// was learned about the key.
    KeyCheckFailed,
};

/// A key the user pasted for a provider with a guided key setup
/// (`ProviderProfile.api_key_setup`). Running it checks the key where the key
/// page says — a GET the provider does not bill, with the key where the
/// provider's requests carry it (`auth`) — and stores it in the provider's
/// own key file. Every string is borrowed; the login worker copies them
/// (`LoginWorker.ownFlow`).
pub const ApiKeyPrepared = struct {
    options: Options,
    provider_id: provider_ids.Slug,
    provider_label: []const u8,
    kind: provider_profile.CredentialKind,
    page: provider_profile.KeyPage,
    secret: []const u8,
    /// Where the check carries the key: the profile's own scheme, so a key
    /// is checked the way it will be sent (Gemini reads `x-goog-api-key`
    /// and answers a bearer token 401 whatever the key).
    auth: provider_profile.AuthScheme = .bearer,
    /// What a refusal other than 401/403 means, in the provider's words
    /// (`ProviderProfile.classify_error`): Gemini refuses a wrong key with
    /// 400 `API_KEY_INVALID`.
    classify_error: provider_profile.ClassifyFn = provider_profile.defaultClassifyError,
    /// False stores the key without the check (`login --no-check`).
    check: bool = true,

    pub fn run(
        self: ApiKeyPrepared,
        allocator: std.mem.Allocator,
        io: std.Io,
        notify: oauth_login.Notify,
        diagnostic: ?*ImportDiagnostic,
    ) !Outcome {
        _ = diagnostic;
        if (self.check) if (keyCheckOverride() orelse self.page.check_url) |url| {
            var line: [512]u8 = undefined;
            notify.say(std.fmt.bufPrint(&line, "Checking the key with {s}\n", .{url}) catch "Checking the key\n");
            if (self.aborted()) return error.Aborted;
            const answer = catalog_fetch.fetchAnswer(allocator, io, .{
                .url = url,
                .credential = .{ .scheme = self.auth, .secret = self.secret },
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.KeyCheckFailed,
            };
            defer allocator.free(answer.body);
            try keyCheckVerdict(allocator, answer, self.classify_error);
            if (self.aborted()) return error.Aborted;
        };
        try api_key_store.save(
            allocator,
            self.options.state_root,
            self.provider_id,
            self.kind,
            self.secret,
            self.page.id.slice(),
            time.nowUnix(),
        );
        var line: [256]u8 = undefined;
        notify.say(std.fmt.bufPrint(&line, "Stored the key for {s}.\n", .{self.provider_label}) catch "Stored the key.\n");
        return .{ .provider_id = self.provider_id, .client_id_source = .declared };
    }

    fn aborted(self: ApiKeyPrepared) bool {
        const signal = self.options.abort_signal orelse return false;
        return signal.isAborted();
    }
};

/// What the check's answer says about the key. 401 and 403 refuse it, as
/// does any status the provider classifies as an invalid key or a denial
/// (`ProviderProfile.classify_error`: Gemini's 400 `API_KEY_INVALID`). A 2xx
/// passes only as the provider's own answer (`checkAnswered`). Anything else
/// — 429, 5xx, a 3xx that was not followed — learned nothing about the key.
fn keyCheckVerdict(
    allocator: std.mem.Allocator,
    answer: catalog_fetch.Answer,
    classify: provider_profile.ClassifyFn,
) KeyError!void {
    if (answer.status >= 200 and answer.status < 300) {
        if (!checkAnswered(allocator, answer.body)) return error.KeyCheckFailed;
        return;
    }
    if (answer.status == 401 or answer.status == 403) return error.KeyRefused;
    return switch (classify(answer.status, answer.body)) {
        .auth_invalid, .auth_expired, .permission_denied => error.KeyRefused,
        else => error.KeyCheckFailed,
    };
}

test "key login: the check refuses on 401/403 and on what the provider calls an invalid key, and learns nothing from the rest" {
    const a = std.testing.allocator;
    const Verdict = struct {
        fn of(status: u16, body: []const u8, classify: provider_profile.ClassifyFn) KeyError!void {
            var copy: [256]u8 = undefined;
            @memcpy(copy[0..body.len], body);
            return keyCheckVerdict(a, .{ .status = status, .body = copy[0..body.len] }, classify);
        }
        fn gemini(status: u16, body: []const u8) provider_profile.ErrorClass {
            if (status == 400 and std.mem.indexOf(u8, body, "API_KEY_INVALID") != null) return .auth_invalid;
            return provider_profile.defaultClassifyError(status, body);
        }
    };
    const default = provider_profile.defaultClassifyError;
    try Verdict.of(200, "{\"data\":[]}", default);
    try std.testing.expectError(error.KeyCheckFailed, Verdict.of(200, "<html></html>", default));
    try std.testing.expectError(error.KeyRefused, Verdict.of(401, "{}", default));
    try std.testing.expectError(error.KeyRefused, Verdict.of(403, "", default));
    try std.testing.expectError(error.KeyCheckFailed, Verdict.of(429, "{}", default));
    try std.testing.expectError(error.KeyCheckFailed, Verdict.of(500, "{}", default));
    try std.testing.expectError(error.KeyCheckFailed, Verdict.of(302, "", default));
    // 400 says nothing about the key, unless the provider says it does.
    const invalid = "{\"error\":{\"code\":400,\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"reason\":\"API_KEY_INVALID\"}]}}";
    try std.testing.expectError(error.KeyCheckFailed, Verdict.of(400, invalid, default));
    try std.testing.expectError(error.KeyRefused, Verdict.of(400, invalid, Verdict.gemini));
    try std.testing.expectError(error.KeyCheckFailed, Verdict.of(400, "{\"error\":{\"status\":\"FAILED_PRECONDITION\"}}", Verdict.gemini));
}

/// A 2xx from the check is a pass only when it is the provider answering: a
/// JSON object that does not report failure. A captive portal or proxy page
/// answers 200 with HTML, and Z.AI answers some failures with 200 and
/// `"success": false`; neither says anything about the key.
fn checkAnswered(allocator: std.mem.Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    if (object.get("error")) |value| if (value != .null) return false;
    if (object.get("success")) |value| if (value == .bool and !value.bool) return false;
    return true;
}

test "a key check passes only on the provider's own answer" {
    const a = std.testing.allocator;
    try std.testing.expect(checkAnswered(a, "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5.3\"}]}"));
    try std.testing.expect(checkAnswered(a, "{\"data\":[],\"error\":null}"));
    try std.testing.expect(!checkAnswered(a, "<html><body>Sign in to the Wi-Fi</body></html>"));
    try std.testing.expect(!checkAnswered(a, "{\"success\":false,\"msg\":\"token invalid\"}"));
    try std.testing.expect(!checkAnswered(a, "{\"error\":{\"code\":\"1000\"}}"));
    try std.testing.expect(!checkAnswered(a, "[1,2]"));
    try std.testing.expect(!checkAnswered(a, ""));
}

/// `METACODES_KEY_CHECK_URL` replaces every key page's check (development and
/// tests: a local mock, the way `METASK_GATEWAY_URL` points Metask at one).
/// Only https or plain http to a loopback address is accepted: the check
/// carries the key.
pub fn keyCheckOverride() ?[]const u8 {
    const raw = std.c.getenv("METACODES_KEY_CHECK_URL") orelse return null;
    const url = std.mem.span(raw);
    return if (keyCheckUrlAccepted(url)) url else null;
}

fn keyCheckUrlAccepted(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    const rest = if (std.mem.startsWith(u8, url, "http://")) url["http://".len..] else return false;
    // The host exactly, not a prefix: `localhost.example.com` is not local.
    const end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
    const host = if (std.mem.startsWith(u8, rest, "[::1]")) rest[0.."[::1]".len] else rest[0..end];
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]");
}

test "the key check override takes https or a loopback host, nothing else" {
    try std.testing.expect(keyCheckUrlAccepted("https://relay.example/v4/models"));
    try std.testing.expect(keyCheckUrlAccepted("http://127.0.0.1:9123/api/coding/paas/v4/models"));
    try std.testing.expect(keyCheckUrlAccepted("http://localhost/models"));
    try std.testing.expect(keyCheckUrlAccepted("http://[::1]:8080/models"));
    try std.testing.expect(!keyCheckUrlAccepted("http://localhost.example.com/models"));
    try std.testing.expect(!keyCheckUrlAccepted("http://127.0.0.1.example.com/models"));
    try std.testing.expect(!keyCheckUrlAccepted("http://example.com/models"));
    try std.testing.expect(!keyCheckUrlAccepted("ftp://127.0.0.1/models"));
}

/// A variable `profile` reads its key from, set where credential resolution
/// looks before a stored key (`credential.resolve`: the process
/// environment, then `<state root>/.env`). While one is set, a key `/login
/// <provider>` stores is not the one used: the login says so, by the
/// variable's name and never its value.
pub const KeyShadow = struct {
    name: []const u8,
    /// Set in `<state root>/.env` rather than in the process environment.
    in_local_config: bool,
};

/// The first of `profile`'s key variables that would win over a stored key:
/// the process environment's, else the `.env` layer's (`local_config`).
pub fn keyShadowedBy(
    profile: *const provider_profile.ProviderProfile,
    process: provider_credential.EnvLookup,
    local_config: ?provider_credential.EnvLookup,
) ?KeyShadow {
    for (profile.env_aliases) |alias| {
        if (process.get(alias.name) != null) return .{ .name = alias.name, .in_local_config = false };
    }
    const layer = local_config orelse return null;
    for (profile.env_aliases) |alias| {
        if (layer.get(alias.name) != null) return .{ .name = alias.name, .in_local_config = true };
    }
    return null;
}

/// `GEMINI_API_KEY is set in your shell and is used before the stored key:
/// unset it to use the key you just stored.`, or for `.env` `GEMINI_API_KEY
/// in <env_path> is used before the stored key: remove it from that file to
/// use the key you just stored.` One line, no newline.
pub fn writeKeyShadowNotice(w: *std.Io.Writer, shadow: KeyShadow, env_path: []const u8) std.Io.Writer.Error!void {
    if (shadow.in_local_config) {
        try w.print("{s} in {s} is used before the stored key: remove it from that file to use the key you just stored.", .{ shadow.name, env_path });
    } else {
        try w.print("{s} is set in your shell and is used before the stored key: unset it to use the key you just stored.", .{shadow.name});
    }
}

test "key login: a key variable set in the shell, else in .env, is named as winning over the stored key" {
    const Env = struct {
        names: []const []const u8,
        fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            for (self.names) |set| if (std.mem.eql(u8, set, name)) return "value-never-named";
            return null;
        }
        fn lookup(self: *const @This()) provider_credential.EnvLookup {
            return .{ .ctx = @ptrCast(@constCast(self)), .getFn = get };
        }
    };
    const gemini = &@import("../provider/profiles/gemini.zig").PROFILE;
    const none: Env = .{ .names = &.{} };
    const shell: Env = .{ .names = &.{"GOOGLE_API_KEY"} };
    const file: Env = .{ .names = &.{"GEMINI_API_KEY"} };
    try std.testing.expect(keyShadowedBy(gemini, none.lookup(), none.lookup()) == null);
    try std.testing.expect(keyShadowedBy(gemini, none.lookup(), null) == null);
    // The shell's comes first, as resolution reads it first.
    const from_shell = keyShadowedBy(gemini, shell.lookup(), file.lookup()).?;
    try std.testing.expectEqualStrings("GOOGLE_API_KEY", from_shell.name);
    try std.testing.expect(!from_shell.in_local_config);
    const from_file = keyShadowedBy(gemini, none.lookup(), file.lookup()).?;
    try std.testing.expectEqualStrings("GEMINI_API_KEY", from_file.name);
    try std.testing.expect(from_file.in_local_config);

    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeKeyShadowNotice(&w, from_shell, "/s/.env");
    try std.testing.expectEqualStrings("GOOGLE_API_KEY is set in your shell and is used before the stored key: unset it to use the key you just stored.", w.buffered());
    w = .fixed(&buffer);
    try writeKeyShadowNotice(&w, from_file, "/s/.env");
    try std.testing.expectEqualStrings("GEMINI_API_KEY in /s/.env is used before the stored key: remove it from that file to use the key you just stored.", w.buffered());
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "value-never-named") == null);
}

pub const KeySetupError = error{
    /// The profile declares no guided key setup.
    NoKeySetup,
    UnknownKeyPage,
    EmptyKey,
};

/// The key flow for `profile`: the page `page_id` names, else the default page
/// for `channel_id`'s region. The key is trimmed of surrounding whitespace,
/// which a paste routinely carries.
pub fn prepareApiKey(
    profile: *const provider_profile.ProviderProfile,
    page_id: ?[]const u8,
    channel_id: ?provider_ids.Slug,
    secret: []const u8,
    options: Options,
) KeySetupError!ApiKeyPrepared {
    const setup = profile.api_key_setup orelse return error.NoKeySetup;
    const page = if (page_id) |id| profile.keyPage(id) orelse return error.UnknownKeyPage else profile.defaultKeyPage(channel_id) orelse return error.NoKeySetup;
    const key = std.mem.trim(u8, secret, " \t\r\n");
    if (key.len == 0) return error.EmptyKey;
    return .{
        .options = options,
        .provider_id = profile.id,
        .provider_label = profile.display_name,
        .kind = setup.kind,
        .page = page,
        .secret = key,
        .auth = profile.auth,
        .classify_error = profile.classify_error,
    };
}

/// A sign-in on the provider's site that hands back an API key of the user's
/// own account (`ProviderProfile.key_grant`, OpenRouter). Two ways: the
/// browser on this machine (loopback redirect), or another device, whose page
/// shows a code the user pastes back (`pasted`). Every string is borrowed;
/// the login worker copies them (`LoginWorker.ownFlow`).
pub const KeyGrantPrepared = struct {
    options: Options,
    provider_id: provider_ids.Slug,
    provider_label: []const u8,
    /// The key setup's kind: the key is stored as a pasted one would be.
    kind: provider_profile.CredentialKind,
    grant: provider_profile.KeyGrant,
    /// `grant.origin`, or the development override (`openrouter_login.origin`).
    origin: []const u8,
    /// The other-device way, once the user pasted the code. Null runs the
    /// loopback way.
    pasted: ?Pasted = null,

    pub const Pasted = struct {
        code: []const u8,
        /// The verifier the page address was made with (`openrouter_login.Pending`).
        verifier: []const u8,
    };

    pub fn run(
        self: KeyGrantPrepared,
        allocator: std.mem.Allocator,
        io: std.Io,
        notify: oauth_login.Notify,
        diagnostic: ?*ImportDiagnostic,
    ) !Outcome {
        _ = diagnostic;
        const target: openrouter_login.Target = .{
            .provider_id = self.provider_id,
            .provider_label = self.provider_label,
            .kind = self.kind,
            .state_root = self.options.state_root,
        };
        if (self.pasted) |pasted| {
            try openrouter_login.finish(allocator, io, self.origin, self.grant, target, pasted.code, pasted.verifier, self.options.abort_signal);
        } else {
            try openrouter_login.signInWithBrowser(
                allocator,
                io,
                self.origin,
                self.grant,
                target,
                self.options.open_browser,
                self.options.port,
                self.options.abort_signal,
                notify,
            );
        }
        return .{ .provider_id = self.provider_id, .client_id_source = .declared };
    }
};

/// The key grant `profile` declares, ready to run the loopback way; null when
/// it declares none.
pub fn prepareKeyGrant(profile: *const provider_profile.ProviderProfile, options: Options) ?KeyGrantPrepared {
    const grant = profile.key_grant orelse return null;
    const setup = profile.api_key_setup orelse return null;
    return .{
        .options = options,
        .provider_id = profile.id,
        .provider_label = profile.display_name,
        .kind = setup.kind,
        .grant = grant,
        .origin = openrouter_login.origin(grant),
    };
}

/// A sign-in that passed every refusal check: the generic OAuth grant for a
/// profile, Metask's own device grant, a provider's key grant, or a pasted
/// API key. The TUI's login worker runs any of them.
pub const Flow = union(enum) {
    oauth: Prepared,
    metask: MetaskPrepared,
    api_key: ApiKeyPrepared,
    key_grant: KeyGrantPrepared,

    pub fn options(self: *Flow) *Options {
        return switch (self.*) {
            .oauth => |*prepared| &prepared.options,
            .metask => |*prepared| &prepared.options,
            .api_key => |*prepared| &prepared.options,
            .key_grant => |*prepared| &prepared.options,
        };
    }

    pub fn run(
        self: Flow,
        allocator: std.mem.Allocator,
        io: std.Io,
        notify: oauth_login.Notify,
        diagnostic: ?*ImportDiagnostic,
    ) !Outcome {
        return switch (self) {
            .oauth => |prepared| prepared.run(allocator, io, notify, diagnostic),
            .metask => |prepared| prepared.run(allocator, io, notify, diagnostic),
            .api_key => |prepared| prepared.run(allocator, io, notify, diagnostic),
            .key_grant => |prepared| prepared.run(allocator, io, notify, diagnostic),
        };
    }
};

/// The flow `/login` runs for `profile`: Metask's own grant, the provider's
/// key grant, or the generic one when the profile passes `prepareProfileWith`.
pub fn prepareFlow(profile: *const provider_profile.ProviderProfile, options: Options, configured: ?[]const u8) FlowError!Flow {
    if (profile.id.eqlText("metask")) {
        try requireOAuthCapable(profile);
        if (options.client_id != null) return error.ClientIdFixed;
        return .{ .metask = .{ .options = options } };
    }
    if (prepareKeyGrant(profile, options)) |prepared| {
        // The grant presents no client: an OAuth client id has nothing to do.
        if (options.client_id != null) return error.ClientIdFixed;
        return .{ .key_grant = prepared };
    }
    return .{ .oauth = try prepareProfileWith(profile, options, configured) };
}

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
/// the caller already resolved and no installation-configured client; the
/// host-aware entry points use `prepareProfileWith`.
pub fn prepareProfile(profile: *const provider_profile.ProviderProfile, options: Options) PrepareError!Prepared {
    return prepareProfileWith(profile, options, null);
}

/// `prepareProfile` with the client the installation configured for this
/// profile (`Host.oauthClientIdFor`, #87). Precedence: the caller's explicit
/// client, then the configured one, then the profile's declaration — the
/// configured client is the installation's own registration, so it stands in
/// for a declaration and overrides one, exactly as `--client-id` does.
pub fn prepareProfileWith(
    profile: *const provider_profile.ProviderProfile,
    options: Options,
    configured: ?[]const u8,
) PrepareError!Prepared {
    try requireOAuthCapable(profile);
    // A profile with no authorization or device endpoint has no interactive
    // flow to run; say so instead of failing later at a null URL.
    const endpoint_declared = switch (options.method) {
        .loopback => profile.oauth_authorize_url != null,
        .device_code => profile.oauth_device_authorization_url != null,
    };
    if (!endpoint_declared) return error.FlowUnavailable;
    const source: ClientIdSource = if (options.client_id != null)
        .explicit
    else if (configured != null)
        .configured
    else
        .declared;
    const client_id = options.client_id orelse configured orelse profile.oauth_client_id orelse
        return error.ClientIdMissing;
    return .{
        .profile = profile,
        .client_id = client_id,
        .client_id_source = source,
        .options = options,
    };
}

/// `prepareProfile` for a provider named the way the user names it.
pub fn prepare(host: *provider_host.Host, provider_name: []const u8, options: Options) Error!Prepared {
    const profile = host.registry.find(provider_name) orelse return error.UnknownProvider;
    return prepareProfileWith(profile, options, host.oauthClientIdFor(profile.id));
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
    state_root: []const u8,
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

    var session = provider_oauth.Session.initHome(allocator, state_root, provider_id) catch |err|
        return failed(diagnostic, err, error.StoreOpenFailed);
    defer session.deinit();
    // Recorded before the import so it lands in the same atomic write as the
    // tokens: a refresh that presents a different client is rejected outright.
    // Metask's JSON refresh grant uses the fixed public `metacodes` client;
    // other provider profiles retain their registered client.
    session.setClientId(if (provider_id.eqlText("metask")) null else client_id) catch |err|
        return failed(diagnostic, err, error.ClientRecordFailed);
    session.importOutcome(outcome, time.nowUnix()) catch |err|
        return failed(diagnostic, err, error.TokenStoreFailed);
}

fn failed(diagnostic: ?*ImportDiagnostic, cause: anyerror, err: ImportError) ImportError {
    if (diagnostic) |out| out.cause = cause;
    return err;
}

test "the client id precedence is explicit, then configured, then declared" {
    const kinds = [_]provider_profile.CredentialKind{.openai_oauth};
    var undeclared = provider_profile.ProviderProfile{
        .id = provider_ids.Slug.lit("undeclared"),
        .implementation_id = provider_ids.Slug.lit("undeclared"),
        .display_name = "Undeclared",
        .channels = &.{},
        .accepted_credential_kinds = &kinds,
        .oauth_token_url = "https://auth.example.com/token",
        .oauth_authorize_url = "https://auth.example.com/authorize",
    };
    // No declaration, nothing configured, nothing explicit: refused.
    try std.testing.expectError(error.ClientIdMissing, prepareProfileWith(&undeclared, .{ .state_root = "" }, null));
    // The installation's client stands in for the missing declaration.
    const configured = try prepareProfileWith(&undeclared, .{ .state_root = "" }, "app_installation");
    try std.testing.expectEqual(ClientIdSource.configured, configured.client_id_source);
    try std.testing.expectEqualStrings("app_installation", configured.client_id);
    // An explicit client wins over the configured one.
    const explicit = try prepareProfileWith(&undeclared, .{ .client_id = "cli-client", .state_root = "" }, "app_installation");
    try std.testing.expectEqual(ClientIdSource.explicit, explicit.client_id_source);
    try std.testing.expectEqualStrings("cli-client", explicit.client_id);
    // The configured client overrides a declaration, like --client-id does.
    undeclared.oauth_client_id = "declared-client";
    const overridden = try prepareProfileWith(&undeclared, .{ .state_root = "" }, "app_installation");
    try std.testing.expectEqual(ClientIdSource.configured, overridden.client_id_source);
    try std.testing.expectEqualStrings("app_installation", overridden.client_id);
    const declared = try prepareProfileWith(&undeclared, .{ .state_root = "" }, null);
    try std.testing.expectEqual(ClientIdSource.declared, declared.client_id_source);
    try std.testing.expectEqualStrings("declared-client", declared.client_id);
}

test "prepareFlow: a provider with a key grant runs it, from the profile's origin, and refuses a client id" {
    const openrouter = @import("../provider/profiles/openrouter.zig").PROFILE;
    const flow = try prepareFlow(&openrouter, .{ .state_root = "/state", .open_browser = false }, null);
    try std.testing.expect(flow == .key_grant);
    try std.testing.expectEqualStrings("https://openrouter.ai", flow.key_grant.origin);
    try std.testing.expectEqual(provider_profile.CredentialKind.api_key, flow.key_grant.kind);
    try std.testing.expect(flow.key_grant.pasted == null);
    try std.testing.expectError(error.ClientIdFixed, prepareFlow(&openrouter, .{ .state_root = "/state", .client_id = "x" }, null));
}

test "prepareFlow: Metask runs its own grant and refuses a client id it would ignore" {
    const metask_profile = @import("../provider/profiles/metask.zig").PROFILE;
    const flow = try prepareFlow(&metask_profile, .{ .state_root = "/state", .open_browser = false }, null);
    try std.testing.expect(flow == .metask);
    try std.testing.expect(!flow.metask.options.open_browser);
    try std.testing.expectError(error.ClientIdFixed, prepareFlow(&metask_profile, .{ .state_root = "/state", .client_id = "x" }, null));
}
