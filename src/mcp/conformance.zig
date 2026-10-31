//! Protocol conformance of the shared client, run with no CLI, no AgentCore and
//! no AgentLoop: an in-memory peer behind the Host transport adapter, under both
//! entry-point profiles. A test here that runs under `both` says the two entry
//! points behave the same given the same frames; one that names a profile pins
//! a retained difference (doc/MCP_ARCHITECTURE.md lists them).
//!
//! Stream-only behaviour (a server ping, a stale answer, a `list_changed`
//! between frames) is pinned against real processes and sockets in
//! tests/integration/mcp_{protocol,http,sse_oauth}_test.zig.

const std = @import("std");
const canonical = @import("canonical.zig");
const wire = @import("wire.zig");
const negotiation = @import("negotiation.zig");
const client_mod = @import("client.zig");
const host = @import("host_transport.zig");
const runtime = @import("runtime.zig");
const result_budget = @import("../core/result_budget.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

const McpClient = client_mod.McpClient;
const Profile = client_mod.Profile;
const allocator = std.testing.allocator;

const CallScript = enum {
    complete,
    input_required_then_complete,
    sampling_required,
    business_error,
    control_characters,
    null_id_error,
    malformed,
    no_jsonrpc,
    padded,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
    fatal,
    abort_during_call,
};

const Peer = struct {
    era: canonical.Era = .modern_2026_07_28,
    call: CallScript = .complete,
    padding: usize = 0,
    /// tools/list pages: the n-th answer's `nextCursor`. Null ends the list.
    cursors: []const ?[]const u8 = &.{null},
    opens: u32 = 0,
    closes: u32 = 0,
    calls: u32 = 0,
    lists: u32 = 0,
    resource_requests: u32 = 0,
    saw_empty_cursor: bool = false,
    last_call: [4096]u8 = undefined,
    last_call_len: usize = 0,
    abort_target: ?*AbortSignal = null,
    saw_cancellation: bool = false,
    list_index: usize = 0,

    const Connection = struct { owner: *Peer };

    fn connector(self: *Peer) host.Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, _: host.ConnectionPurpose, _: canonical.Era) anyerror!host.OpenOutcome {
        const self: *Peer = @ptrCast(@alignCast(raw));
        const connection = try std.heap.c_allocator.create(Connection);
        connection.* = .{ .owner = self };
        self.opens += 1;
        return .{ .connection = .{
            .ctx = connection,
            .request_fn = request,
            .tool_request = .{ .completed = request },
            .notify_fn = notify,
            .close_fn = close,
        } };
    }

    fn notify(_: *anyopaque, _: []const u8, _: u32, _: host.Cancellation) anyerror!void {}

    fn close(raw: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        connection.owner.closes += 1;
        std.heap.c_allocator.destroy(connection);
    }

    fn requestId(encoded: []const u8) u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return 0) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch 0;
    }

    fn contains(encoded: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, encoded, needle) != null;
    }

    fn respond(a: std.mem.Allocator, body: []u8) host.ExchangeOutcome {
        _ = a;
        return .{ .response = .{ .http_status = 0, .body = body } };
    }

    fn request(
        raw: *anyopaque,
        a: std.mem.Allocator,
        encoded: []const u8,
        _: u32,
        cancellation: host.Cancellation,
    ) anyerror!host.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.owner;
        const id = requestId(encoded);
        const modern_era = self.era.isModern();
        if (contains(encoded, "\"method\":\"server/discover\"")) {
            if (!modern_era) return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id}));
            return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{\"tools\":{{}},\"resources\":{{}}}},\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}", .{id}));
        }
        if (contains(encoded, "\"method\":\"initialize\"")) {
            return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{}}}},\"serverInfo\":{{\"name\":\"peer\",\"version\":\"1\"}}}}}}", .{ id, self.era.version() }));
        }
        if (contains(encoded, "\"method\":\"tools/list\"")) {
            self.lists += 1;
            if (contains(encoded, "\"cursor\":\"\"")) self.saw_empty_cursor = true;
            const index = @min(self.list_index, self.cursors.len - 1);
            self.list_index += 1;
            const cache: []const u8 = if (modern_era) "\"resultType\":\"complete\",\"ttlMs\":1000,\"cacheScope\":\"private\"," else "";
            if (self.cursors[index]) |cursor| {
                return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{{s}\"tools\":[{{\"name\":\"tool{d}\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"nextCursor\":\"{s}\"}}}}", .{ id, cache, index, cursor }));
            }
            return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{{s}\"tools\":[{{\"name\":\"tool{d}\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{ id, cache, index }));
        }
        if (contains(encoded, "\"method\":\"resources/list\"")) {
            self.resource_requests += 1;
            return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resources\":[{{\"uri\":\"mem://one\",\"name\":\"one\"}}]}}}}", .{id}));
        }
        if (contains(encoded, "\"method\":\"resources/read\"")) {
            self.resource_requests += 1;
            return respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":[{{\"uri\":\"mem://one\",\"text\":\"body\"}}]}}}}", .{id}));
        }
        std.debug.assert(contains(encoded, "\"method\":\"tools/call\""));
        self.calls += 1;
        self.last_call_len = @min(encoded.len, self.last_call.len);
        @memcpy(self.last_call[0..self.last_call_len], encoded[0..self.last_call_len]);
        const retried = contains(encoded, "\"inputResponses\"");
        return switch (self.call) {
            .complete => respond(a, try completeFrame(a, id, self.era, "\"ok\"", 0)),
            .input_required_then_complete => if (retried)
                respond(a, try completeFrame(a, id, self.era, "\"after input\"", 0))
            else
                respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"input_required\",\"inputRequests\":{{\"q\":{{\"method\":\"elicitation/create\",\"params\":{{\"message\":\"who\"}}}}}},\"requestState\":\"opaque-state\"}}}}", .{id})),
            .sampling_required => respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"input_required\",\"inputRequests\":{{\"q\":{{\"method\":\"sampling/createMessage\",\"params\":{{}}}}}}}}}}", .{id})),
            .business_error => respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"city unavailable\"}}],\"isError\":true}}}}", .{id})),
            .control_characters => respond(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"\\u001b[31mred\"}}]}}}}", .{id})),
            .null_id_error => respond(a, try a.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Bad Request\"}}")),
            .malformed => respond(a, try a.dupe(u8, "not json")),
            .no_jsonrpc => respond(a, try std.fmt.allocPrint(a, "{{\"id\":{d},\"result\":{{\"content\":[]}}}}", .{id})),
            .padded => respond(a, try completeFrame(a, id, self.era, "\"x\"", self.padding)),
            .timeout => .timeout,
            .network_error => .network_error,
            .auth_error => .auth_error,
            .server_error => .server_error,
            .child_exit => .child_exit,
            .cancelled => .cancelled,
            .indeterminate => .indeterminate,
            .fatal => .fatal,
            .abort_during_call => blk: {
                self.abort_target.?.abort(.user_interrupt);
                self.saw_cancellation = cancellation.isCancelled();
                break :blk .cancelled;
            },
        };
    }

    fn completeFrame(a: std.mem.Allocator, id: u64, era: canonical.Era, text: []const u8, padding: usize) ![]u8 {
        const fill = try a.alloc(u8, padding);
        defer a.free(fill);
        @memset(fill, 'p');
        const result_type: []const u8 = if (era.isModern()) "\"resultType\":\"complete\"," else "";
        return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{{s}\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"padding\":\"{s}\"}}}}", .{ id, result_type, text, fill });
    }
};

/// The two entry points' protocol behaviour, over the same adapter. A Host
/// connection's frames need no bigger limits than the strict default.
const profiles = [_]Profile{ Profile.hostContract(.{}), Profile.product };

fn connect(peer: *Peer, profile: Profile, policy: negotiation.Policy) !McpClient {
    var opener = runtime.HostOpener{
        .gpa = allocator,
        .connector = peer.connector(),
        .transport = .stdio,
        .timeout_ms = 1000,
    };
    return switch (client_mod.establish(allocator, .{
        .opener = opener.interface(),
        .transport_kind = .stdio,
        .policy = policy,
        .profile = profile,
        .client = .{ .name = "conformance", .version = "1" },
    })) {
        .connected => |client| client,
        .failed => |failed| failed.err,
    };
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.root = self.root_buffer[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buffer)];
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn call(self: *const Fixture, client: *McpClient, abort: ?*const AbortSignal) client_mod.BodyOutcome {
        return client.invokeTool(allocator, .{
            .name = "weather",
            .arguments_json = "{\"city\":\"Paris\"}",
            .artifact_root = self.root,
            .budget = result_budget.Budget.fromModel(200_000),
            .abort = abort,
        });
    }
};

fn deinitOutcome(outcome: *client_mod.BodyOutcome) void {
    switch (outcome.*) {
        .result => |*body| body.deinit(allocator),
        .failed => |failed| if (failed.detail) |detail| allocator.free(detail),
    }
}

test "both profiles: the same frames give the same tool result, in every era both speak" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const eras = [_]canonical.Era{ .modern_2026_07_28, .classic_2025_11_25 };
    for (eras) |era| {
        var bodies: [profiles.len][]u8 = undefined;
        for (profiles, 0..) |profile, index| {
            var peer = Peer{ .era = era };
            var client = try connect(&peer, profile, .auto);
            defer client.close();
            try std.testing.expectEqual(era, client.era);
            var outcome = fixture.call(&client, null);
            defer deinitOutcome(&outcome);
            try std.testing.expect(outcome == .result);
            bodies[index] = try allocator.dupe(u8, outcome.result.@"inline".bytes);
            try std.testing.expectEqual(@as(u32, 1), peer.calls);
        }
        defer for (bodies) |body| allocator.free(body);
        try std.testing.expectEqualStrings(bodies[0], bodies[1]);
    }
}

test "both profiles: a tool's own error is a structured error, not a success" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var peer = Peer{ .call = .business_error };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        var outcome = fixture.call(&client, null);
        defer deinitOutcome(&outcome);
        try std.testing.expect(outcome == .result);
        try std.testing.expect(outcome.result == .structured_error);
        try std.testing.expect(std.mem.indexOf(u8, outcome.result.structured_error.encoded, "city unavailable") != null);
    }
}

test "both profiles: content may carry escaped control characters" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var peer = Peer{ .call = .control_characters };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        var outcome = fixture.call(&client, null);
        defer deinitOutcome(&outcome);
        try std.testing.expect(outcome == .result);
        try std.testing.expect(std.mem.indexOf(u8, outcome.result.@"inline".bytes, "\\u001b[31mred") != null);
    }
}

test "both profiles: a result above the budget is sealed, not published, below it inline" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var peer = Peer{ .call = .padded, .padding = 30_000 };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        {
            var sealed = fixture.call(&client, null);
            defer deinitOutcome(&sealed);
            try std.testing.expect(sealed == .result);
            try std.testing.expect(sealed.result == .sealed);
            // Nothing reaches the CAS before the batch commits.
            if (fixture.tmp.dir.openDir(std.testing.io, "tool-results/sha256", .{ .iterate = true })) |opened| {
                var cas = opened;
                defer cas.close(std.testing.io);
                var entries = cas.iterate();
                try std.testing.expect((try entries.next(std.testing.io)) == null);
            } else |err| try std.testing.expectEqual(error.FileNotFound, err);
        }
        peer.padding = 20_000;
        var inlined = fixture.call(&client, null);
        defer deinitOutcome(&inlined);
        try std.testing.expect(inlined.result == .@"inline");
    }
}

test "both profiles: a frame above the materialize bound goes through the same projector" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var peer = Peer{ .call = .padded, .padding = client_mod.CONTROL_FRAME_MATERIALIZE_BYTES + 4096 };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        var outcome = fixture.call(&client, null);
        defer deinitOutcome(&outcome);
        try std.testing.expect(outcome == .result);
        try std.testing.expect(outcome.result == .sealed);
        // Only a frame already in memory is kept inline when publishing fails.
        try std.testing.expectEqual(
            @as(u64, result_budget.PER_RESULT_MAX_BYTES),
            outcome.result.sealed.retain_inline_ceiling,
        );
    }
}

test "profiles differ: the failed-publication ceiling of a bounded frame" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const expected = [_]u64{ result_budget.PER_RESULT_MAX_BYTES, client_mod.CONTROL_FRAME_MATERIALIZE_BYTES };
    for (profiles, expected) |profile, ceiling| {
        var peer = Peer{ .call = .padded, .padding = 30_000 };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        var outcome = fixture.call(&client, null);
        defer deinitOutcome(&outcome);
        try std.testing.expectEqual(ceiling, outcome.result.sealed.retain_inline_ceiling);
    }
}

test "both profiles: resources are listed and read over the Host adapter" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var peer = Peer{};
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        try std.testing.expect(client.capabilities.resources);
        const listed = try client.listResources();
        defer allocator.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, "mem://one") != null);
        const read = try client.readResource("mem://one");
        defer allocator.free(read);
        try std.testing.expect(std.mem.indexOf(u8, read, "\"text\":\"body\"") != null);
        var body = try client.readResourceBodyAbortable("mem://one", fixture.root, .{}, null);
        defer body.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, body.@"inline".bytes, "\"text\":\"body\"") != null);
        var list_body = try client.listResourcesBodyAbortable(fixture.root, .{}, null);
        defer list_body.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, list_body.@"inline".bytes, "mem://one") != null);
        try std.testing.expectEqual(@as(u32, 4), peer.resource_requests);
    }
}

fn acceptElicitation(ctx: *anyopaque, params_json: []const u8, alloc: std.mem.Allocator) ?[]u8 {
    const seen: *bool = @ptrCast(@alignCast(ctx));
    seen.* = std.mem.indexOf(u8, params_json, "who") != null;
    return alloc.dupe(u8, "{\"name\":\"metacodes\"}") catch null;
}

test "input continuation is a policy: enabled it retries with the answer and the echoed state" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var profile = Profile.hostContract(.{});
    profile.input_continuation = true;
    var peer = Peer{ .call = .input_required_then_complete };
    var client = try connect(&peer, profile, .auto);
    defer client.close();
    var seen = false;
    client.elicit = .{ .ctx = @ptrCast(&seen), .handleFn = acceptElicitation };
    var outcome = fixture.call(&client, null);
    defer deinitOutcome(&outcome);
    try std.testing.expect(outcome == .result);
    try std.testing.expect(seen);
    try std.testing.expectEqual(@as(u32, 2), peer.calls);
    const retry = peer.last_call[0..peer.last_call_len];
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"requestState\":\"opaque-state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"action\":\"accept\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"name\":\"metacodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry, "\"city\":\"Paris\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.result.@"inline".bytes, "after input") != null);
}

test "input continuation is a policy: disabled it is terminal, once, and the client stays usable" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var peer = Peer{ .call = .input_required_then_complete };
    var client = try connect(&peer, Profile.hostContract(.{}), .auto);
    defer client.close();
    var outcome = fixture.call(&client, null);
    defer deinitOutcome(&outcome);
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqual(canonical.DiagnosticCode.input_required_unsupported, outcome.failed.failure.diagnostic.code);
    try std.testing.expectEqual(canonical.Disposition.answered, outcome.failed.disposition);
    try std.testing.expectEqual(@as(u32, 1), peer.calls);
    try std.testing.expect(client.isUsable());
    peer.call = .complete;
    var next = fixture.call(&client, null);
    defer deinitOutcome(&next);
    try std.testing.expect(next == .result);
}

test "a request the client cannot fulfil ends the call without another attempt" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var peer = Peer{ .call = .sampling_required };
    var client = try connect(&peer, Profile.product, .auto);
    defer client.close();
    var outcome = fixture.call(&client, null);
    defer deinitOutcome(&outcome);
    try std.testing.expectEqual(error.McpInputUnsupported, outcome.failed.err);
    try std.testing.expectEqual(canonical.Disposition.answered, outcome.failed.disposition);
    try std.testing.expectEqual(@as(u32, 1), peer.calls);
}

test "both profiles: an unanswered call is indeterminate and is never replayed; a refused one is not" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const cases = [_]struct { script: CallScript, disposition: canonical.Disposition, tag: std.meta.Tag(client_mod.CallFailure) }{
        .{ .script = .timeout, .disposition = .indeterminate, .tag = .timeout },
        .{ .script = .network_error, .disposition = .indeterminate, .tag = .network_error },
        .{ .script = .server_error, .disposition = .indeterminate, .tag = .server_error },
        .{ .script = .child_exit, .disposition = .indeterminate, .tag = .child_exit },
        .{ .script = .cancelled, .disposition = .indeterminate, .tag = .cancelled },
        .{ .script = .indeterminate, .disposition = .indeterminate, .tag = .indeterminate },
        .{ .script = .auth_error, .disposition = .not_delivered, .tag = .auth_error },
    };
    for (profiles) |profile| {
        for (cases) |case| {
            var peer = Peer{ .call = case.script };
            var client = try connect(&peer, profile, .auto);
            defer client.close();
            var outcome = fixture.call(&client, null);
            defer deinitOutcome(&outcome);
            try std.testing.expect(outcome == .failed);
            try std.testing.expectEqual(case.tag, std.meta.activeTag(outcome.failed.failure));
            try std.testing.expectEqual(case.disposition, outcome.failed.disposition);
            try std.testing.expectEqual(@as(u32, 1), peer.calls);
            try std.testing.expect(client.isUsable());
        }
    }
}

test "both profiles: a connector contract failure retires the connection" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var peer = Peer{ .call = .fatal };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        var first = fixture.call(&client, null);
        defer deinitOutcome(&first);
        try std.testing.expect(first.failed.failure == .indeterminate);
        try std.testing.expectEqual(canonical.Disposition.indeterminate, first.failed.disposition);
        try std.testing.expect(!client.isUsable());
        try std.testing.expectEqual(peer.opens, peer.closes);
        var second = fixture.call(&client, null);
        defer deinitOutcome(&second);
        try std.testing.expect(second.failed.failure == .instance_unavailable);
        try std.testing.expectEqual(canonical.Disposition.not_delivered, second.failed.disposition);
        try std.testing.expectEqual(@as(u32, 1), peer.calls);
    }
}

test "both profiles: cancellation before the send reaches nobody; during the call the connector sees it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (profiles) |profile| {
        var signal = AbortSignal.init();
        var peer = Peer{ .call = .abort_during_call, .abort_target = &signal };
        var client = try connect(&peer, profile, .auto);
        defer client.close();
        var during = fixture.call(&client, &signal);
        defer deinitOutcome(&during);
        try std.testing.expect(during.failed.failure == .cancelled);
        try std.testing.expectEqual(canonical.Disposition.indeterminate, during.failed.disposition);
        try std.testing.expect(peer.saw_cancellation);
        try std.testing.expectEqual(@as(u32, 1), peer.calls);

        // Already interrupted: the request is known not to have left.
        var before = fixture.call(&client, &signal);
        defer deinitOutcome(&before);
        try std.testing.expect(before.failed.failure == .cancelled);
        try std.testing.expectEqual(canonical.Disposition.not_delivered, before.failed.disposition);
        try std.testing.expectEqual(@as(u32, 1), peer.calls);
    }
}

test "profiles differ: revision window, and how a selection below the offer is taken" {
    const older = [_]canonical.Era{ .classic_2025_03_26, .classic_2024_11_05 };
    for (older) |era| {
        var adopted = Peer{ .era = era };
        var product = try connect(&adopted, Profile.product, .auto);
        defer product.close();
        try std.testing.expectEqual(era, product.era);
        try std.testing.expectEqualStrings(era.version(), product.protocol_version);
        // The probe's connection carried the handshake: one child, not two.
        try std.testing.expectEqual(@as(u32, 1), adopted.opens);

        var refused = Peer{ .era = era };
        try std.testing.expectError(error.UnsupportedProtocolVersion, connect(&refused, Profile.hostContract(.{}), .auto));
        try std.testing.expectEqual(refused.opens, refused.closes);
    }
}

test "profiles differ: who owns the discovery probe's connection" {
    var reused = Peer{};
    var product = try connect(&reused, Profile.product, .auto);
    defer product.close();
    try std.testing.expectEqual(@as(u32, 1), reused.opens);
    try std.testing.expectEqual(@as(u32, 0), reused.closes);

    var disposable = Peer{};
    var strict = try connect(&disposable, Profile.hostContract(.{}), .auto);
    defer strict.close();
    try std.testing.expectEqual(@as(u32, 2), disposable.opens);
    try std.testing.expectEqual(@as(u32, 1), disposable.closes);
}

test "profiles differ: a frame short of the specification" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    {
        var peer = Peer{ .call = .no_jsonrpc };
        var product = try connect(&peer, Profile.product, .auto);
        defer product.close();
        var tolerated = fixture.call(&product, null);
        defer deinitOutcome(&tolerated);
        try std.testing.expect(tolerated == .result);

        var strict_peer = Peer{ .call = .no_jsonrpc };
        var strict = try connect(&strict_peer, Profile.hostContract(.{}), .auto);
        defer strict.close();
        var refused = fixture.call(&strict, null);
        defer deinitOutcome(&refused);
        try std.testing.expectEqual(canonical.DiagnosticCode.invalid_envelope, refused.failed.failure.diagnostic.code);
    }
    {
        // How many HTTP servers report a request they could not parse.
        var peer = Peer{ .call = .null_id_error };
        var product = try connect(&peer, Profile.product, .auto);
        defer product.close();
        var remote = fixture.call(&product, null);
        defer deinitOutcome(&remote);
        try std.testing.expectEqual(canonical.DiagnosticCode.remote_error, remote.failed.failure.diagnostic.code);
        try std.testing.expect(std.mem.indexOf(u8, remote.failed.detail.?, "Bad Request") != null);

        var strict_peer = Peer{ .call = .null_id_error };
        var strict = try connect(&strict_peer, Profile.hostContract(.{}), .auto);
        defer strict.close();
        var refused = fixture.call(&strict, null);
        defer deinitOutcome(&refused);
        try std.testing.expectEqual(canonical.DiagnosticCode.response_id_mismatch, refused.failed.failure.diagnostic.code);
    }
    {
        var peer = Peer{ .call = .malformed };
        var product = try connect(&peer, Profile.product, .auto);
        defer product.close();
        var failed = fixture.call(&product, null);
        defer deinitOutcome(&failed);
        try std.testing.expectEqual(error.McpMalformedResponse, failed.failed.err);

        var strict_peer = Peer{ .call = .malformed };
        var strict = try connect(&strict_peer, Profile.hostContract(.{}), .auto);
        defer strict.close();
        var refused = fixture.call(&strict, null);
        defer deinitOutcome(&refused);
        try std.testing.expectEqual(canonical.DiagnosticCode.invalid_json, refused.failed.failure.diagnostic.code);
    }
}

test "pagination: an empty cursor is a cursor, a repeated one is a failure" {
    const empty_then_end = [_]?[]const u8{ "", null };
    var peer = Peer{ .era = .classic_2025_11_25, .cursors = &empty_then_end };
    var client = try connect(&peer, Profile.product, .auto);
    defer client.close();
    const tools = try client.listTools();
    defer allocator.free(tools);
    try std.testing.expect(std.mem.indexOf(u8, tools, "tool0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "tool1") != null);
    try std.testing.expect(peer.saw_empty_cursor);
    try std.testing.expectEqual(@as(u32, 2), peer.lists);

    const repeating = [_]?[]const u8{ "again", "again" };
    var loop = Peer{ .era = .classic_2025_11_25, .cursors = &repeating };
    var looping = try connect(&loop, Profile.product, .auto);
    defer looping.close();
    try std.testing.expectError(error.McpRepeatedCursor, looping.listTools());
    try std.testing.expectEqual(@as(u32, 2), loop.lists);
}

test "profiles differ: the catalog bound truncates the product list and fails the strict one" {
    const pages = [_]?[]const u8{ "a", "b", "c", null };
    var truncating = Profile.product;
    truncating.limits.max_tools = 2;
    var peer = Peer{ .era = .classic_2025_11_25, .cursors = &pages };
    var client = try connect(&peer, truncating, .auto);
    defer client.close();
    const tools = try client.listTools();
    defer allocator.free(tools);
    try std.testing.expect(std.mem.indexOf(u8, tools, "tool1") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "tool2") == null);

    var strict_peer = Peer{ .era = .classic_2025_11_25, .cursors = &pages };
    const connected = runtime.connectServer(allocator, .{
        .connector = strict_peer.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{0x77} ** 32,
        .client = .{ .name = "conformance", .version = "1" },
        .limits = .{ .max_tools = 2 },
    });
    try std.testing.expect(connected == .failed and connected.failed == .resource_limit);
    try std.testing.expectEqual(strict_peer.opens, strict_peer.closes);
}

test "arguments that are not one JSON object never leave the client" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var peer = Peer{};
    var client = try connect(&peer, Profile.product, .auto);
    defer client.close();
    var outcome = client.invokeTool(allocator, .{
        .name = "weather",
        .arguments_json = "[1]",
        .artifact_root = fixture.root,
        .budget = .{},
    });
    defer deinitOutcome(&outcome);
    try std.testing.expectEqual(error.McpInvalidParams, outcome.failed.err);
    try std.testing.expectEqual(canonical.Disposition.not_delivered, outcome.failed.disposition);
    try std.testing.expectEqual(@as(u32, 0), peer.calls);
}

test "errors of a stream client's clients keep their names under one classification" {
    const failed = client_mod.callFailureOf(error.McpOutcomeIndeterminate);
    try std.testing.expect(failed == .indeterminate);
    try std.testing.expect(client_mod.connectFailureOf(error.McpAuthRequired) == .auth_error);
    try std.testing.expect(client_mod.connectFailureOf(error.McpConnectionFatal) == .fatal);
    _ = wire.Conformance.strict;
}
