//! What to do next when a model request failed because the sign-in or key was
//! rejected or the balance ran out. Retrying cannot help there, so the last
//! line of the failure says what can; every other failure keeps the advice the
//! caller had (`/retry` in the TUI, nothing more under `-p`).
//!
//! `render` is the whole mapping and a pure function: the failure as
//! `api/model_error.zig` classified it (its category and the upstream code it
//! parsed), the route (Metask, or another provider's display name and the
//! variable its key is read from), this install's `<state root>/.env`, and
//! where the line is shown. The TUI names its slash commands; `-p` names the
//! command line instead: `<command> login` for `/login` (#482), `--provider`
//! for `/model`.
//!
//! - HTTP 401 or 403 (`authentication`, `permission`): the credential was
//!   rejected. Metask: sign in again. Another provider: check its key where
//!   it is read from, then restart.
//! - HTTP 402 (`payment_required`), or the upstream code `insufficient_balance`,
//!   `insufficient_quota` or `key_quota_exhausted` whatever the status (OpenAI
//!   answers a used-up quota with 429): top up, or switch provider.
//! - The upstream code `account_suspended` (Metask's gateway answers it with
//!   a 403): the account itself is suspended, which signing in again cannot
//!   cure. See to it on the provider's site, or switch provider.
//!
//! Neither retries nor switches anything. `forFailure` gathers the inputs from
//! a session. Host-only: the library reports the failure and never knows the
//! `.env` path.

const std = @import("std");
const model_error = @import("../api/model_error.zig");
const auth = @import("../core/auth.zig");
const app_mod = @import("../app.zig");
const profile_mod = @import("../provider/profile.zig");
const provider_host_mod = @import("../provider/host.zig");
const state_env = @import("../app/state_env.zig");

/// Where the line is shown.
pub const Surface = union(enum) {
    /// The TUI: `/login`, `/model`.
    interactive,
    /// `-p`: the command the user ran (`app/invocation.zig`), for `<command> login`.
    print: []const u8,
};

/// The provider the failed request went to.
pub const Route = union(enum) {
    metask,
    provider: Provider,

    pub const Provider = struct {
        /// `ProviderProfile.display_name`.
        name: []const u8,
        /// The canonical variable its key is read from; null when the profile
        /// declares none.
        key_variable: ?[]const u8,
    };
};

/// Why a retry cannot help.
pub const Situation = enum {
    /// HTTP 401 or 403: the sign-in or the key was not accepted.
    credential_rejected,
    /// HTTP 402, or an upstream code that says the balance or quota is gone.
    balance_exhausted,
    /// `account_suspended`: the account behind the credential is suspended.
    account_suspended,
};

/// The upstream codes that mean no balance or quota is left, whatever the
/// status says.
const balance_codes = [_][]const u8{ "insufficient_balance", "insufficient_quota", "key_quota_exhausted" };

/// The situation `category` and the upstream `code` describe; null for every
/// other failure. A code that names the balance outranks the status.
pub fn situation(category: model_error.Category, code: ?[]const u8) ?Situation {
    if (code) |value| {
        // A suspended account is refused like a bad credential (403), but
        // a new sign-in or key cannot cure it: the code outranks the status.
        if (std.mem.eql(u8, value, "account_suspended")) return .account_suspended;
        for (balance_codes) |known| {
            if (std.mem.eql(u8, value, known)) return .balance_exhausted;
        }
    }
    return switch (category) {
        .payment_required => .balance_exhausted,
        .authentication, .permission => .credential_rejected,
        .not_found,
        .invalid_request,
        .context_window,
        .rate_limited,
        .overloaded,
        .server_error,
        .timeout,
        .connection,
        .stream_interrupted,
        .output_limit,
        .unknown,
        => null,
    };
}

pub const Input = struct {
    category: model_error.Category,
    /// The upstream code `model_error` parsed, if any.
    code: ?[]const u8 = null,
    route: Route,
    /// This install's `<state root>/.env`; empty when it has no state root.
    env_path: []const u8 = "",
    surface: Surface,
};

/// The line that says what to do next, owned by the caller, or null to keep
/// the advice the caller had.
pub fn render(allocator: std.mem.Allocator, input: Input) error{OutOfMemory}!?[]u8 {
    const which = situation(input.category, input.code) orelse return null;
    const switch_provider = switch (input.surface) {
        .interactive => "/model",
        .print => "--provider",
    };
    return switch (which) {
        .credential_rejected => switch (input.route) {
            .metask => switch (input.surface) {
                .interactive => try allocator.dupe(u8, "Your Metask sign-in is no longer valid. Sign in again: /login"),
                .print => |command| try std.fmt.allocPrint(allocator, "Your Metask sign-in is no longer valid. Sign in again: {s} login", .{command}),
            },
            .provider => |provider| try keyRejected(allocator, provider, input.env_path),
        },
        .balance_exhausted => switch (input.route) {
            .metask => try std.fmt.allocPrint(allocator, "Your Metask balance has run out. Top up your Metask account, or switch provider: {s}", .{switch_provider}),
            .provider => |provider| try std.fmt.allocPrint(allocator, "{s} reports no balance or quota left. Top up with {s}, or switch provider: {s}", .{ provider.name, provider.name, switch_provider }),
        },
        .account_suspended => switch (input.route) {
            .metask => try std.fmt.allocPrint(allocator, "Your Metask account is suspended. See to it at {s}, or switch provider: {s}", .{ auth.METASK_SITE_URL, switch_provider }),
            .provider => |provider| try std.fmt.allocPrint(allocator, "{s} reports the account is suspended. See to it with {s}, or switch provider: {s}", .{ provider.name, provider.name, switch_provider }),
        },
    };
}

/// Where the rejected key is read from: the provider's variable, in this
/// install's `.env` or the shell. Without a state root there is no `.env`;
/// without a variable there is no name to give.
fn keyRejected(allocator: std.mem.Allocator, provider: Route.Provider, env_path: []const u8) error{OutOfMemory}![]u8 {
    const variable = provider.key_variable orelse
        return std.fmt.allocPrint(allocator, "{s} rejected the API key. Check the key configured for it, then restart.", .{provider.name});
    if (env_path.len == 0)
        return std.fmt.allocPrint(allocator, "{s} rejected the API key. Check {s} in your shell, then restart.", .{ provider.name, variable });
    return std.fmt.allocPrint(allocator, "{s} rejected the API key. Check {s} in {s} or your shell, then restart.", .{ provider.name, variable, env_path });
}

/// Whether `failure` is one `render` speaks for, from the failure alone: a
/// caller can skip gathering the rest when it is not.
pub fn applies(failure: *const model_error.Detail) bool {
    const view = failure.view();
    return situation(view.category, view.code) != null;
}

/// The line for `failure`, the model failure a Run of `app` just stopped on,
/// or null to keep the caller's advice. The caller owns it. May build the
/// session's provider host to name the route.
pub fn forFailure(
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    failure: *const model_error.Detail,
    surface: Surface,
) error{OutOfMemory}!?[]u8 {
    if (!applies(failure)) return null;
    const route = routeOf(app) orelse return null;
    const state_root = app.stateRoot();
    // `<state root>/.env` as the file's own reader names it (state_env.load).
    const env_path = if (state_root.len == 0) "" else try std.fs.path.join(allocator, &.{ state_root, state_env.file_name });
    defer if (env_path.len > 0) allocator.free(env_path);
    const view = failure.view();
    return render(allocator, .{
        .category = view.category,
        .code = view.code,
        .route = route,
        .env_path = env_path,
        .surface = surface,
    });
}

/// The provider this session's requests go to: the route the kernel has in
/// force (a `--provider` start, a stored default, a `/model` pick), else the
/// one startup resolved, else the historical path, which is Metask. Null when
/// that provider is not in the registry.
pub fn routeOf(app: *app_mod.App) ?Route {
    const host = app.providerHost() catch null;
    if (host) |live| if (currentProfile(live)) |profile| return routeFor(profile.*);
    const name = app.config.resolved_provider_id orelse app.config.provider_profile orelse return .metask;
    if (std.ascii.eqlIgnoreCase(name, "metask")) return .metask;
    const live = host orelse return null;
    const profile = live.registry.find(name) orelse return null;
    return routeFor(profile.*);
}

/// The profile of the offer the kernel has in force. The retired catalog is
/// read too: a provider disabled since keeps the session it is running.
fn currentProfile(host: *provider_host_mod.Host) ?*const profile_mod.ProviderProfile {
    const current = host.kernel.currentOfferId() orelse return null;
    const offer = host.kernel.catalogSnapshot().find(current) orelse
        (if (host.retired) |*previous| previous.find(current) else null) orelse
        return null;
    return host.registry.findById(offer.provider_id);
}

pub fn routeFor(profile: profile_mod.ProviderProfile) Route {
    if (profile.id.eqlText("metask")) return .metask;
    return .{ .provider = .{ .name = profile.display_name, .key_variable = keyVariable(profile) } };
}

/// The canonical variable of the first credential kind the profile accepts
/// that has one, as its credential help names it.
fn keyVariable(profile: profile_mod.ProviderProfile) ?[]const u8 {
    for (profile.accepted_credential_kinds) |kind| {
        if (profile.canonicalEnvAlias(kind)) |name| return name;
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const deepseek: Route = .{ .provider = .{ .name = "DeepSeek", .key_variable = "DEEPSEEK_API_KEY" } };
const state_env_path = "/home/u/.local/opt/metacodes/state/.env";

/// `render`'s line for `input`; "" when it keeps the caller's advice.
fn lineFor(input: Input) ![]u8 {
    return (try render(testing.allocator, input)) orelse try testing.allocator.dupe(u8, "");
}

fn expectLine(expected: []const u8, input: Input) !void {
    const line = try lineFor(input);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings(expected, line);
}

test "a rejected Metask sign-in, 401 or 403, says sign in again" {
    for ([_]model_error.Category{ .authentication, .permission }) |category| {
        try expectLine("Your Metask sign-in is no longer valid. Sign in again: /login", .{
            .category = category,
            .code = "authentication_error",
            .route = .metask,
            .env_path = state_env_path,
            .surface = .interactive,
        });
    }
}

test "another provider's rejected key names its variable and this install's .env" {
    try expectLine("DeepSeek rejected the API key. Check DEEPSEEK_API_KEY in " ++ state_env_path ++ " or your shell, then restart.", .{
        .category = .authentication,
        .route = deepseek,
        .env_path = state_env_path,
        .surface = .interactive,
    });
    try expectLine("Kimi Code rejected the API key. Check KIMI_CODE_API_KEY in " ++ state_env_path ++ " or your shell, then restart.", .{
        .category = .permission,
        .route = .{ .provider = .{ .name = "Kimi Code", .key_variable = "KIMI_CODE_API_KEY" } },
        .env_path = state_env_path,
        .surface = .interactive,
    });
    // No state root: no file to name. No variable: no name to give.
    try expectLine("DeepSeek rejected the API key. Check DEEPSEEK_API_KEY in your shell, then restart.", .{
        .category = .authentication,
        .route = deepseek,
        .surface = .interactive,
    });
    try expectLine("House relay rejected the API key. Check the key configured for it, then restart.", .{
        .category = .authentication,
        .route = .{ .provider = .{ .name = "House relay", .key_variable = null } },
        .env_path = state_env_path,
        .surface = .interactive,
    });
}

test "HTTP 402 says top up or switch provider" {
    try expectLine("Your Metask balance has run out. Top up your Metask account, or switch provider: /model", .{
        .category = .payment_required,
        .code = "insufficient_balance",
        .route = .metask,
        .surface = .interactive,
    });
    // The status alone decides, with any code or none.
    try expectLine("DeepSeek reports no balance or quota left. Top up with DeepSeek, or switch provider: /model", .{
        .category = .payment_required,
        .route = deepseek,
        .env_path = state_env_path,
        .surface = .interactive,
    });
}

test "429 with insufficient_quota is a used-up quota, not a rate limit" {
    try expectLine("OpenAI reports no balance or quota left. Top up with OpenAI, or switch provider: /model", .{
        .category = .rate_limited,
        .code = "insufficient_quota",
        .route = .{ .provider = .{ .name = "OpenAI", .key_variable = "OPENAI_API_KEY" } },
        .surface = .interactive,
    });
    try testing.expectEqual(@as(?Situation, null), situation(.rate_limited, "rate_limit_exceeded"));
    try testing.expectEqual(@as(?Situation, null), situation(.rate_limited, null));
}

test "the upstream code insufficient_balance names the balance whatever the status" {
    for ([_]model_error.Category{ .invalid_request, .unknown, .authentication, .permission, .server_error }) |category| {
        try expectLine("Your Metask balance has run out. Top up your Metask account, or switch provider: /model", .{
            .category = category,
            .code = "insufficient_balance",
            .route = .metask,
            .surface = .interactive,
        });
    }
    try testing.expectEqual(@as(?Situation, .balance_exhausted), situation(.unknown, "insufficient_quota"));
    // Only those exact codes: a code that merely mentions one is not it.
    try testing.expectEqual(@as(?Situation, null), situation(.invalid_request, "Insufficient_Balance"));
    try testing.expectEqual(@as(?Situation, null), situation(.invalid_request, "insufficient_balance_warning"));
}

test "a suspended account says so, not sign in again, whatever the status" {
    try expectLine("Your Metask account is suspended. See to it at https://www.metask-ai.com, or switch provider: /model", .{
        .category = .permission,
        .code = "account_suspended",
        .route = .metask,
        .env_path = state_env_path,
        .surface = .interactive,
    });
    try expectLine("DeepSeek reports the account is suspended. See to it with DeepSeek, or switch provider: --provider", .{
        .category = .authentication,
        .code = "account_suspended",
        .route = .{ .provider = .{ .name = "DeepSeek", .key_variable = "DEEPSEEK_API_KEY" } },
        .env_path = state_env_path,
        .surface = .{ .print = "metacodes" },
    });
}

test "the gateway's key_quota_exhausted is a used-up quota" {
    try expectLine("Your Metask balance has run out. Top up your Metask account, or switch provider: /model", .{
        .category = .permission,
        .code = "key_quota_exhausted",
        .route = .metask,
        .env_path = state_env_path,
        .surface = .interactive,
    });
}

test "every other failure keeps the caller's advice" {
    for (std.enums.values(model_error.Category)) |category| {
        const expected: ?Situation = switch (category) {
            .authentication, .permission => .credential_rejected,
            .payment_required => .balance_exhausted,
            else => null,
        };
        try testing.expectEqual(expected, situation(category, null));
        // An upstream code that names something else changes nothing.
        try testing.expectEqual(expected, situation(category, "billing_error"));
        if (expected != null) continue;
        for ([_]Route{ .metask, deepseek }) |route| {
            for ([_]Surface{ .interactive, .{ .print = "metacodes" } }) |surface| {
                try testing.expectEqual(@as(?[]u8, null), try render(testing.allocator, .{
                    .category = category,
                    .code = "server_error",
                    .route = route,
                    .env_path = state_env_path,
                    .surface = surface,
                }));
            }
        }
    }
}

test "-p names the command that was run and --provider instead of the slash commands" {
    const print: Surface = .{ .print = "metacodes-dev" };
    try expectLine("Your Metask sign-in is no longer valid. Sign in again: metacodes-dev login", .{
        .category = .authentication,
        .route = .metask,
        .surface = print,
    });
    try expectLine("Your Metask balance has run out. Top up your Metask account, or switch provider: --provider", .{
        .category = .payment_required,
        .route = .metask,
        .surface = print,
    });
    try expectLine("DeepSeek reports no balance or quota left. Top up with DeepSeek, or switch provider: --provider", .{
        .category = .rate_limited,
        .code = "insufficient_quota",
        .route = deepseek,
        .surface = print,
    });
    // A rejected key names no command: the line is the TUI's.
    try expectLine("DeepSeek rejected the API key. Check DEEPSEEK_API_KEY in " ++ state_env_path ++ " or your shell, then restart.", .{
        .category = .authentication,
        .route = deepseek,
        .env_path = state_env_path,
        .surface = print,
    });
    for ([_]Situation{ .credential_rejected, .balance_exhausted }) |which| {
        const category: model_error.Category = if (which == .credential_rejected) .authentication else .payment_required;
        for ([_]Route{ .metask, deepseek }) |route| {
            const line = try lineFor(.{ .category = category, .route = route, .env_path = state_env_path, .surface = print });
            defer testing.allocator.free(line);
            try testing.expect(std.mem.indexOf(u8, line, "/login") == null);
            try testing.expect(std.mem.indexOf(u8, line, "/model") == null);
            try testing.expect(std.mem.indexOf(u8, line, "/retry") == null);
        }
    }
}

test "every built-in provider names its key's variable; Metask is the Metask route" {
    const registry = @import("../provider/registry.zig");
    for (registry.BUILTIN_PROFILES) |profile| {
        switch (routeFor(profile)) {
            .metask => try testing.expect(profile.id.eqlText("metask")),
            .provider => |provider| {
                try testing.expectEqualStrings(profile.display_name, provider.name);
                if (provider.key_variable == null) {
                    std.debug.print("{s} declares no key variable\n", .{profile.id.slice()});
                    return error.TestUnexpectedResult;
                }
            },
        }
    }
    // The kind decides, not `.api_key`: Kimi Code's and the GLM plan's keys
    // are kinds of their own. OpenAI also takes OAuth kinds, which have none.
    try testing.expectEqualStrings("DEEPSEEK_API_KEY", routeFor(registry.deepseek.PROFILE).provider.key_variable.?);
    try testing.expectEqualStrings("KIMI_CODE_API_KEY", routeFor(registry.kimi_code.PROFILE).provider.key_variable.?);
    try testing.expectEqualStrings("ZAI_API_KEY", routeFor(registry.zai_coding_plan.PROFILE).provider.key_variable.?);
    try testing.expectEqualStrings("OPENAI_API_KEY", routeFor(registry.openai.PROFILE).provider.key_variable.?);
}
