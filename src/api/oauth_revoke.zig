//! Signing out of a provider's OAuth sign-in: revoke, then delete.
//!
//! A provider whose profile declares a revocation endpoint
//! (`ProviderProfile.oauth_revocation`, RFC 7009) is asked to end the refresh
//! token before the local login (`<state root>/oauth/<provider>.json`) is
//! deleted, so the grant does not stay alive at the vendor once the only copy
//! here is gone. Best effort and bounded, as Metask's sign-out is
//! (`metask_oauth.revokeStoredSession`): the request runs on its own thread
//! with its own copies, the caller waits `wait_ms` at most, and the local
//! login is deleted whatever the answer.
//!
//! Only the refresh token is sent, and only to the endpoint the provider's own
//! profile names; the access token goes nowhere.

const std = @import("std");
const oauth = @import("../provider/oauth.zig");
const provider_ids = @import("../provider/ids.zig");
const provider_profile = @import("../provider/profile.zig");
const http_status = @import("http_status.zig");
const http_connection = @import("http_connection.zig");
const util_json = @import("../util/json.zig");
const util_time = @import("../util/time.zig");
const auth = @import("../core/auth.zig");

/// How long a sign-out waits for the revocation before it deletes anyway.
pub const DEFAULT_WAIT_MS: u64 = 5_000;

/// What the revocation found and did.
pub const RevokeOutcome = enum {
    /// The endpoint answered 2xx: the grant ends there too.
    revoked,
    /// No login is stored: there is nothing to revoke.
    nothing_stored,
    /// The profile declares no revocation endpoint; the login is only
    /// deleted, and its refresh token stays valid at the vendor until it
    /// expires.
    not_offered,
    /// The request failed or was refused.
    failed,
    /// No answer within the wait; the request may still finish.
    timed_out,
};

pub const Forgotten = struct {
    /// A stored login was there and is deleted.
    removed: bool = false,
    revoke: RevokeOutcome = .nothing_stored,
};

/// Revoke `profile`'s stored login where the profile says, then delete it.
pub fn forgetStoredLogin(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    profile: *const provider_profile.ProviderProfile,
    wait_ms: u64,
) error{ OutOfMemory, RemoveFailed }!Forgotten {
    const revoke: RevokeOutcome = if (profile.oauth_revocation) |revocation|
        revokeStoredLogin(state_root, profile.id, revocation, profile.oauth_client_id, wait_ms)
    else if (loginStored(allocator, state_root, profile.id)) .not_offered else .nothing_stored;
    const removed = try oauth.Session.removeStored(allocator, state_root, profile.id);
    return .{ .removed = removed, .revoke = revoke };
}

fn loginStored(allocator: std.mem.Allocator, state_root: []const u8, provider_id: provider_ids.Slug) bool {
    var session = oauth.Session.initHome(allocator, state_root, provider_id) catch return false;
    defer session.deinit();
    return session.load() catch false;
}

/// Revoke the refresh token of `provider_id`'s stored login at `revocation`,
/// presenting the client the login recorded (else `declared_client`).
pub fn revokeStoredLogin(
    state_root: []const u8,
    provider_id: provider_ids.Slug,
    revocation: provider_profile.OAuthRevocation,
    declared_client: ?[]const u8,
    wait_ms: u64,
) RevokeOutcome {
    // The request may outlive the caller's wait: nothing it holds is the
    // caller's.
    const gpa = std.heap.page_allocator;
    var session = oauth.Session.initHome(gpa, state_root, provider_id) catch return .failed;
    defer session.deinit();
    if (!(session.load() catch false)) return .nothing_stored;
    const tokens = session.tokens orelse return .nothing_stored;
    const job = RevokeJob.create(gpa, revocation, session.clientIdFor(declared_client), tokens.refresh_token) catch return .failed;
    const thread = @import("platform").thread.spawn(.full, RevokeJob.run, .{job}) catch {
        // Only the caller's share is left.
        _ = job.owners.fetchSub(1, .acq_rel);
        job.release();
        return .failed;
    };
    thread.detach();
    var waited: u64 = 0;
    while (waited < wait_ms and job.result.load(.acquire) == 0) : (waited += 50) util_time.sleepMs(50);
    const result = job.result.load(.acquire);
    job.release();
    return switch (result) {
        1 => .revoked,
        2 => .failed,
        else => .timed_out,
    };
}

/// The revocation request's body (RFC 7009 §2.1): the refresh token, hinted
/// as one, and the client it was issued to, as the endpoint takes them.
pub fn requestBody(
    allocator: std.mem.Allocator,
    encoding: provider_profile.OAuthRevocation.Body,
    client_id: []const u8,
    refresh_token: []const u8,
) ![]u8 {
    switch (encoding) {
        .form => {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try auth.appendFormField(&aw.writer, "token", refresh_token, true);
            try auth.appendFormField(&aw.writer, "token_type_hint", "refresh_token", false);
            try auth.appendFormField(&aw.writer, "client_id", client_id, false);
            return aw.toOwnedSlice();
        },
        .json => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, "{\"token\":");
            try util_json.serializeString(refresh_token, &out, allocator);
            try out.appendSlice(allocator, ",\"token_type_hint\":\"refresh_token\",\"client_id\":");
            try util_json.serializeString(client_id, &out, allocator);
            try out.append(allocator, '}');
            return out.toOwnedSlice(allocator);
        },
    }
}

/// One revocation request, shared by the caller and its thread; the last one
/// to let go frees it (the token zeroed).
const RevokeJob = struct {
    url: []u8,
    body: []u8,
    content_type: []const u8,
    /// 0 while it runs, 1 revoked, 2 failed.
    result: std.atomic.Value(u8) = .init(0),
    owners: std.atomic.Value(u8) = .init(2),

    fn create(
        gpa: std.mem.Allocator,
        revocation: provider_profile.OAuthRevocation,
        client_id: []const u8,
        refresh_token: []const u8,
    ) !*RevokeJob {
        const job = try gpa.create(RevokeJob);
        errdefer gpa.destroy(job);
        const url = try gpa.dupe(u8, revocation.url);
        errdefer gpa.free(url);
        job.* = .{
            .url = url,
            .body = try requestBody(gpa, revocation.body, client_id, refresh_token),
            .content_type = switch (revocation.body) {
                .json => "application/json",
                .form => "application/x-www-form-urlencoded",
            },
        };
        return job;
    }

    fn release(job: *RevokeJob) void {
        if (job.owners.fetchSub(1, .acq_rel) != 1) return;
        const gpa = std.heap.page_allocator;
        std.crypto.secureZero(u8, job.body);
        gpa.free(job.body);
        gpa.free(job.url);
        gpa.destroy(job);
    }

    fn run(job: *RevokeJob) void {
        defer job.release();
        job.result.store(if (job.post()) 1 else 2, .release);
    }

    fn post(job: *const RevokeJob) bool {
        const gpa = std.heap.page_allocator;
        const uri = std.Uri.parse(job.url) catch return false;
        var io_runtime = @import("platform").signal.threadedIo(gpa, .{});
        defer io_runtime.deinit();
        var client = std.http.Client{ .allocator = gpa, .io = io_runtime.io() };
        defer client.deinit();
        // The token travels in the body; only the endpoint that received it
        // can answer.
        var request = client.request(.POST, uri, .{ .redirect_behavior = http_status.no_redirects, .extra_headers = &.{
            .{ .name = "content-type", .value = job.content_type },
            .{ .name = "accept", .value = "application/json" },
        } }) catch return false;
        defer request.deinit();
        http_connection.sendBodyComplete(&request, job.body) catch return false;
        var redirect: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect) catch return false;
        const code = http_status.ResponseStatus.capture(&response).code;
        return code >= 200 and code < 300;
    }
};

test "the revocation body is the refresh token, hinted, and the client, as JSON or a form" {
    const a = std.testing.allocator;
    const json = try requestBody(a, .json, "app_client", "rt/\"quoted\"");
    defer a.free(json);
    try std.testing.expectEqualStrings("{\"token\":\"rt/\\\"quoted\\\"\",\"token_type_hint\":\"refresh_token\",\"client_id\":\"app_client\"}", json);
    const form = try requestBody(a, .form, "app_client", "rt+/=");
    defer a.free(form);
    try std.testing.expectEqualStrings("token=rt%2B%2F%3D&token_type_hint=refresh_token&client_id=app_client", form);
}
