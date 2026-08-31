//! Provider decision audit plane (issue #16).
//!
//! The requirement is explicit that TinyKG must **not** hold configuration: no
//! API keys, no OAuth tokens, no raw endpoint responses, no prompts, and no
//! high-frequency health samples. The live kernel reads the config and session
//! documents and caches on the hot path; graph traversal is never in a request's
//! way.
//!
//! What TinyKG is good for here is the opposite shape — an append-only record of
//! *decisions*: which offer was accepted, at which scope, which route a turn
//! actually took, and which selection failed and why. That is exactly the
//! control plane's event journal, whose payloads are already ids and enums only
//! by construction, with deliberately no free-form field a prompt or token
//! could travel in.
//!
//! This module is a pure projection from those events to audit lines, plus a
//! thin append. It is optional in the strongest sense: when TinyKG is
//! unavailable, `append` reports that and the provider path is unaffected —
//! nothing in route resolution, credential resolution, or request setup calls
//! into it.

const std = @import("std");
const control_plane = @import("../provider/control_plane.zig");
const ids = @import("../provider/ids.zig");

pub const Event = control_plane.ControlPlaneEvent;

/// Domain root for provider decisions. A dedicated root keeps this out of the
/// domain-framing and governance roots the requirement protects.
pub const DOMAIN_ROOT = "metacodes/provider-decisions";

/// Schema type recorded on each node, so a reader can tell an audit line from
/// project knowledge without parsing it.
pub const SCHEMA_TYPE = "metacodes.provider.decision.v1";

pub const MAX_LINE: usize = 320;

/// Render one event as an audit line.
///
/// Returns null for events that carry no decision worth recording. Health
/// samples in particular are deliberately excluded: they are high-frequency
/// observations, and the requirement names them as something that must not
/// accumulate in the graph.
pub fn renderEvent(buffer: []u8, event: Event) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const catalog_revision: u64 = if (event.catalog_revision) |value| value.value() else 0;
    const config_revision: u64 = if (event.config_revision) |value| value.value() else 0;

    switch (event.payload) {
        .runtime_selection_changed => |payload| {
            const offer_id = payload.offer_id orelse return null;
            const rendered = offer_id.render();
            writer.print(
                "selection.accepted scope={s} offer={s} catalog_revision={d} config_revision={d}",
                .{ @tagName(payload.scope), &rendered, catalog_revision, config_revision },
            ) catch return null;
        },
        .runtime_switch_failed => |payload| {
            writer.print(
                "selection.rejected scope={s} reason={s} catalog_revision={d}",
                .{ @tagName(payload.scope), @tagName(payload.reason), catalog_revision },
            ) catch return null;
        },
        .route_actual => |payload| {
            const actual = payload.actual_offer_id.render();
            writer.print(
                "route.actual provider={s} channel={s} protocol={s} offer={s} attempts={d} status={s}",
                .{
                    payload.provider_id.slice(),
                    payload.channel_id.slice(),
                    payload.protocol,
                    &actual,
                    payload.fallback_attempts,
                    @tagName(payload.status),
                },
            ) catch return null;
            // Usage and cost are aggregates, not content, and only when the
            // route reported them.
            if (payload.cost_micros) |cost| writer.print(" cost_micros={d}", .{cost}) catch return null;
            if (payload.latency_ms) |latency| writer.print(" latency_ms={d}", .{latency}) catch return null;
        },
        .failover => |payload| {
            const from = payload.from_offer.render();
            const to = payload.to_offer.render();
            writer.print(
                "route.failover from={s} to={s} attempt={d}",
                .{ &from, &to, payload.attempt },
            ) catch return null;
        },
        .catalog_updated => |payload| {
            writer.print(
                "catalog.updated offers={d} catalog_revision={d}",
                .{ payload.offer_count, catalog_revision },
            ) catch return null;
        },
        .pricing_updated => |payload| {
            writer.print(
                "pricing.updated provider={s} catalog_revision={d}",
                .{ payload.provider_id.slice(), catalog_revision },
            ) catch return null;
        },
        .auth_changed => |payload| {
            writer.print(
                "auth.changed provider={s} credential={s} status={s}",
                .{ payload.provider_id.slice(), payload.credential_ref.slice(), @tagName(payload.status) },
            ) catch return null;
        },
        .credential_expiring => |payload| {
            writer.print(
                "credential.expiring provider={s} credential={s} expires_at={d}",
                .{ payload.provider_id.slice(), payload.credential_ref.slice(), payload.expires_at },
            ) catch return null;
        },
        // High-frequency health observation. Recording every sample is what the
        // requirement rules out; a degradation worth auditing shows up as a
        // failed selection or a failover, both of which are recorded.
        .provider_degraded => return null,
    }
    return writer.buffered();
}

/// Anything that can accept an audit line. A function pointer rather than the
/// KG client type so this module — and its tests — never require a daemon.
pub const Sink = struct {
    ctx: *anyopaque,
    appendFn: *const fn (ctx: *anyopaque, line: []const u8, schema_type: []const u8) anyerror!u64,

    pub fn append(self: Sink, line: []const u8, schema_type: []const u8) anyerror!u64 {
        return self.appendFn(self.ctx, line, schema_type);
    }
};

pub const Summary = struct {
    recorded: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

/// Project a batch of events into the audit plane.
///
/// Failures are counted, never propagated: the audit plane is optional, and a
/// TinyKG outage must not affect a session's ability to route a request.
pub fn recordAll(sink: Sink, events: []const Event) Summary {
    var summary = Summary{};
    var buffer: [MAX_LINE]u8 = undefined;
    for (events) |event| {
        const line = renderEvent(&buffer, event) orelse {
            summary.skipped += 1;
            continue;
        };
        _ = sink.append(line, SCHEMA_TYPE) catch {
            summary.failed += 1;
            continue;
        };
        summary.recorded += 1;
    }
    return summary;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const CollectingSink = struct {
    lines: std.ArrayList([]u8) = .empty,
    allocator: std.mem.Allocator,
    fail: bool = false,

    fn append(ctx: *anyopaque, line: []const u8, schema_type: []const u8) anyerror!u64 {
        const self: *CollectingSink = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.KgUnavailable;
        try testing.expectEqualStrings(SCHEMA_TYPE, schema_type);
        try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
        return self.lines.items.len;
    }

    fn sink(self: *CollectingSink) Sink {
        return .{ .ctx = @ptrCast(self), .appendFn = CollectingSink.append };
    }

    fn deinit(self: *CollectingSink) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }
};

fn selectionEvent(offer: ids.OfferId) Event {
    return .{
        .event_id = 1,
        .stream_sequence = 1,
        .event_type = .runtime_selection_changed,
        .config_revision = @enumFromInt(7),
        .catalog_revision = @enumFromInt(3),
        .payload = .{ .runtime_selection_changed = .{ .scope = .global, .offer_id = offer } },
    };
}

test "an accepted selection records its offer, scope, and revisions" {
    var buffer: [MAX_LINE]u8 = undefined;
    const offer = ids.OfferId{ .digest = @splat(0x2B) };
    const line = renderEvent(&buffer, selectionEvent(offer)).?;

    try testing.expect(std.mem.indexOf(u8, line, "selection.accepted") != null);
    try testing.expect(std.mem.indexOf(u8, line, "scope=global") != null);
    try testing.expect(std.mem.indexOf(u8, line, &offer.render()) != null);
    // Revisions are what make a decision reproducible: they say which catalog
    // and which configuration the choice was made against.
    try testing.expect(std.mem.indexOf(u8, line, "catalog_revision=3") != null);
    try testing.expect(std.mem.indexOf(u8, line, "config_revision=7") != null);
}

test "an actual route records identity and aggregates, and nothing else" {
    var buffer: [MAX_LINE]u8 = undefined;
    const line = renderEvent(&buffer, .{
        .event_id = 2,
        .stream_sequence = 2,
        .event_type = .route_actual,
        .payload = .{ .route_actual = .{
            .requested = .{ .pinned = ids.OfferId{ .digest = @splat(0x11) } },
            .actual_offer_id = ids.OfferId{ .digest = @splat(0x22) },
            .actual_offer_revision = 4,
            .provider_id = ids.Slug.lit("openrouter"),
            .channel_id = ids.Slug.lit("deepinfra"),
            .protocol = "openai_chat",
            .fallback_attempts = 1,
            .cost_micros = 4_200,
            .latency_ms = 640,
            .status = .fell_back,
        } },
    }).?;

    try testing.expect(std.mem.indexOf(u8, line, "provider=openrouter") != null);
    try testing.expect(std.mem.indexOf(u8, line, "channel=deepinfra") != null);
    try testing.expect(std.mem.indexOf(u8, line, "attempts=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "status=fell_back") != null);
    try testing.expect(std.mem.indexOf(u8, line, "cost_micros=4200") != null);
}

test "every recorded line is ids, enums, and numbers — never content" {
    const a = testing.allocator;
    var collector = CollectingSink{ .allocator = a };
    defer collector.deinit();

    const events = [_]Event{
        selectionEvent(ids.OfferId{ .digest = @splat(0x2B) }),
        .{
            .event_id = 2,
            .stream_sequence = 2,
            .event_type = .runtime_switch_failed,
            .payload = .{ .runtime_switch_failed = .{ .scope = .session, .reason = .pinned_offer_unavailable } },
        },
        .{
            .event_id = 3,
            .stream_sequence = 3,
            .event_type = .auth_changed,
            .payload = .{ .auth_changed = .{
                .provider_id = ids.Slug.lit("openai"),
                .credential_ref = ids.Slug.lit("work"),
                .status = .active,
            } },
        },
        .{
            .event_id = 4,
            .stream_sequence = 4,
            .event_type = .catalog_updated,
            .payload = .{ .catalog_updated = .{ .offer_count = 29 } },
        },
    };

    const summary = recordAll(collector.sink(), &events);
    try testing.expectEqual(@as(usize, 4), summary.recorded);
    try testing.expectEqual(@as(usize, 0), summary.failed);

    for (collector.lines.items) |line| {
        // The event payloads carry no free-form field by construction, and the
        // projection adds none. A quoted string or a `sk-`/`Bearer` fragment
        // would mean something content-shaped got through.
        try testing.expect(std.mem.indexOf(u8, line, "sk-") == null);
        try testing.expect(std.mem.indexOf(u8, line, "Bearer") == null);
        try testing.expect(std.mem.indexOfScalar(u8, line, '"') == null);
        try testing.expect(std.mem.indexOf(u8, line, "http") == null);
    }
}

test "health samples are not recorded" {
    var buffer: [MAX_LINE]u8 = undefined;
    // High-frequency observations are exactly what must not accumulate in the
    // graph; a degradation that matters surfaces as a failed selection or a
    // failover, and both of those are recorded.
    try testing.expect(renderEvent(&buffer, .{
        .event_id = 5,
        .stream_sequence = 5,
        .event_type = .provider_degraded,
        .payload = .{ .provider_degraded = .{
            .provider_id = ids.Slug.lit("openrouter"),
            .status = .degraded,
        } },
    }) == null);
}

test "an unavailable audit plane is counted, never propagated" {
    const a = testing.allocator;
    var collector = CollectingSink{ .allocator = a, .fail = true };
    defer collector.deinit();
    const events = [_]Event{selectionEvent(ids.OfferId{ .digest = @splat(0x2B) })};

    // The provider path must work when TinyKG is down. `recordAll` returns a
    // summary rather than an error precisely so no caller can be tempted to
    // propagate one into route resolution.
    const summary = recordAll(collector.sink(), &events);
    try testing.expectEqual(@as(usize, 0), summary.recorded);
    try testing.expectEqual(@as(usize, 1), summary.failed);
}

test "a failed batch reports it, so a caller can decline to advance its cursor" {
    const a = testing.allocator;
    var collector = CollectingSink{ .allocator = a, .fail = true };
    defer collector.deinit();

    const events = [_]Event{
        selectionEvent(ids.OfferId{ .digest = @splat(0x01) }),
        selectionEvent(ids.OfferId{ .digest = @splat(0x02) }),
        // Not recordable: it must count as skipped, not failed, or a caller
        // keying on `failed` would retry a window forever because one event in
        // it is never recordable.
        .{
            .event_id = 3,
            .stream_sequence = 3,
            .event_type = .provider_degraded,
            .payload = .{ .provider_degraded = .{
                .provider_id = ids.Slug.lit("openrouter"),
                .status = .degraded,
            } },
        },
    };

    const failed = recordAll(collector.sink(), &events);
    try testing.expectEqual(@as(usize, 2), failed.failed);
    try testing.expectEqual(@as(usize, 1), failed.skipped);
    try testing.expectEqual(@as(usize, 0), failed.recorded);

    // Once the sink recovers, the same window records cleanly and the caller
    // may advance.
    collector.fail = false;
    const recovered = recordAll(collector.sink(), &events);
    try testing.expectEqual(@as(usize, 0), recovered.failed);
    try testing.expectEqual(@as(usize, 2), recovered.recorded);
}
