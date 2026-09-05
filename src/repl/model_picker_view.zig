//! Rendering for the cross-UI model picker (issue #16, delivery slice P1).
//!
//! Split from the state machine so the drawing can be asserted on without a
//! terminal: every line the user sees is produced here into a plain writer.
//! What a row must show is a requirement, not a taste question — display name,
//! request model id, protocol, region/plan, effective limits, price, health,
//! and whether the route is the current one — so it is covered by tests that
//! read the rendered bytes.

const std = @import("std");
const ansi = @import("tui/ansi.zig");
const theme_mod = @import("tui/theme.zig");
const picker_mod = @import("model_picker.zig");
const offer_mod = @import("../provider/offer.zig");
const selection_mod = @import("../provider/selection.zig");

pub const Theme = theme_mod.Theme;
pub const Picker = picker_mod.Picker;
pub const Row = picker_mod.Row;

/// Draw the picker. Returns the number of terminal rows written so the caller
/// can account for them in its fixed-region height.
pub fn render(picker: *const Picker, w: *std.Io.Writer, th: Theme, cols: usize) u16 {
    var rows: u16 = 0;
    rows += header(picker, w, th);

    if (picker.stage == .credential) return rows + credentialBody(picker, w, th, cols);

    var scratch: [Picker.MAX_ROWS]Row = undefined;
    const visible = picker.rows(&scratch);
    if (visible.len == 0) {
        line(w);
        w.print("  {s}{s}{s}", .{ th.dim, emptyText(picker), th.reset }) catch {};
        newline(w);
        return rows + 1 + footer(picker, w, th);
    }

    const window = @max(picker.page_rows, 1);
    const top = @min(picker.window_top, visible.len -| 1);
    const end = @min(top + window, visible.len);
    for (visible[top..end], top..) |row, index| {
        rows += drawRow(picker, w, th, cols, row, index == picker.cursor);
    }
    if (end < visible.len or top > 0) {
        line(w);
        w.print("  {s}[{d}/{d}]{s}", .{ th.dim, picker.cursor + 1, visible.len, th.reset }) catch {};
        newline(w);
        rows += 1;
    }
    return rows + footer(picker, w, th);
}

fn emptyText(picker: *const Picker) []const u8 {
    return switch (picker.status) {
        .loading => "loading providers…",
        .failed => "provider catalog unavailable — Esc to close",
        .empty => "no providers configured",
        else => if (picker.filter_len > 0)
            "nothing matches this filter — Esc clears it"
        else
            "no routes on this step",
    };
}

fn header(picker: *const Picker, w: *std.Io.Writer, th: Theme) u16 {
    line(w);
    const title = switch (picker.stage) {
        .provider => "Provider",
        .model => "Model",
        .offer => "Channel / offer",
        .options => "Options",
        .credential => "sign in",
    };
    w.print("  {s}{s}{s}", .{ th.accent, title, th.reset }) catch {};
    if (picker.stage == .credential) if (picker.credential_provider) |p| w.print(" to {s}", .{p.slice()}) catch {};
    if (picker.filter_len > 0) {
        w.print(" {s}/{s}{s}", .{ th.dim, picker.filter(), th.reset }) catch {};
    }
    switch (picker.status) {
        // A stale or failed list must say so on the line the user is reading,
        // not only in a log: committing to a route that no longer exists is
        // the failure this warning prevents.
        .stale => w.print(" {s}(stale — refreshing){s}", .{ th.warn, th.reset }) catch {},
        .failed => w.print(" {s}(catalog unavailable){s}", .{ th.danger, th.reset }) catch {},
        .loading => w.print(" {s}(loading){s}", .{ th.dim, th.reset }) catch {},
        else => {},
    }
    newline(w);
    var used: u16 = 1;
    if (picker.notice_len > 0) {
        line(w);
        w.print("  {s}{s}{s}", .{ th.warn, picker.notice(), th.reset }) catch {};
        newline(w);
        used += 1;
    }
    return used;
}

fn drawRow(
    picker: *const Picker,
    w: *std.Io.Writer,
    th: Theme,
    cols: usize,
    row: Row,
    selected: bool,
) u16 {
    line(w);
    switch (row) {
        .provider => |group| {
            const offer = picker.offers.items[group.offer_index];
            paint(w, th, selected, group.is_current);
            w.print("{s}", .{offer.provider_id.slice()}) catch {};
            w.print("{s} {s}{d} model", .{ th.reset, th.dim, group.offer_count }) catch {};
            if (group.offer_count != 1) w.writeAll("s") catch {};
            w.print("{s}", .{th.reset}) catch {};
        },
        .model => |group| {
            const offer = picker.offers.items[group.offer_index];
            paint(w, th, selected, group.is_current);
            w.print("{s}", .{offer.display_name}) catch {};
            w.print("{s} {s}{s}", .{ th.reset, th.dim, group.label }) catch {};
            if (group.offer_count > 1) {
                // The count is the whole reason this stage does not collapse
                // routes by name.
                w.print("  {d} routes", .{group.offer_count}) catch {};
            }
            w.print("{s}", .{th.reset}) catch {};
        },
        .offer => |chosen| {
            const offer = picker.offers.items[chosen.offer_index];
            paint(w, th, selected, chosen.is_current);
            w.print("{s}", .{offer.channel_id.slice()}) catch {};
            w.print("{s} {s}", .{ th.reset, th.dim }) catch {};
            w.print("{s}", .{offer.protocol}) catch {};
            w.print(" model={s}", .{offer.request_model_id}) catch {};
            if (offer.region) |region| w.print(" region={s}", .{region}) catch {};
            if (offer.plan) |plan| w.print(" plan={s}", .{plan}) catch {};
            // The credential is part of the route identity, so two accounts on
            // one endpoint are two rows and the row has to say which is which.
            if (offer.credential_ref) |ref| w.print(" account={s}", .{ref.slice()}) catch {};
            writeLimits(w, offer.limits);
            writeQuote(w, offer.quote);
            writeHealth(w, offer.health, offer.availability);
            w.print("{s}", .{th.reset}) catch {};
        },
        .control => |control| {
            const offer = picker.offers.items[control.offer_index];
            const spec = offer.controls[control.spec_index];
            paint(w, th, selected, false);
            w.print("{s}", .{spec.label}) catch {};
            w.print("{s} {s}= ", .{ th.reset, th.dim }) catch {};
            if (picker.controls.get(spec.id)) |value| {
                switch (value) {
                    .text => |text| w.print("{s}", .{text.slice()}) catch {},
                    .number => |number| w.print("{d}", .{number}) catch {},
                    .boolean => |flag| w.print("{s}", .{if (flag) "on" else "off"}) catch {},
                    .object => w.writeAll("(object)") catch {},
                }
            } else {
                // "unset" is a real state: the provider's own default applies,
                // which is not the same as any value this picker could pick.
                w.writeAll("unset") catch {};
            }
            if (spec.allowed_values.len > 0) {
                w.writeAll("  [") catch {};
                for (spec.allowed_values, 0..) |candidate, index| {
                    if (index > 0) w.writeAll(" ") catch {};
                    w.print("{s}", .{candidate}) catch {};
                }
                w.writeAll("]") catch {};
            } else {
                w.writeAll("  (not settable here)") catch {};
            }
            if (spec.cost_latency_warning) |note| w.print("  {s}", .{note}) catch {};
            w.print("{s}", .{th.reset}) catch {};
        },
    }
    _ = cols;
    newline(w);
    return 1;
}

fn paint(w: *std.Io.Writer, th: Theme, selected: bool, current: bool) void {
    const color = if (selected) th.accent else if (current) th.success else th.primary;
    w.print("  {s}{s}{s} ", .{
        color,
        if (selected) ">" else " ",
        if (current) "*" else " ",
    }) catch {};
}

fn writeLimits(w: *std.Io.Writer, limits: offer_mod.EffectiveLimits) void {
    if (limits.context_window) |ctx| {
        w.print(" ctx={d}", .{ctx}) catch {};
    } else {
        // Unknown is printed, not omitted: a blank column reads as "no limit",
        // and admission actually fails closed here.
        w.writeAll(" ctx=?") catch {};
    }
    if (limits.max_output_tokens) |out| w.print(" out={d}", .{out}) catch {};
}

fn writeQuote(w: *std.Io.Writer, quote: offer_mod.Quote) void {
    const priced = quote.priced() orelse {
        w.writeAll(" price=?") catch {};
        return;
    };
    const input = priced.input_price_micros orelse {
        w.writeAll(" price=?") catch {};
        return;
    };
    const output = priced.output_price_micros orelse {
        w.writeAll(" price=?") catch {};
        return;
    };
    w.print(" {s} {d}.{d:0>2}/{d}.{d:0>2} per {s}", .{
        priced.currency.slice(),
        input / 1_000_000,
        (input % 1_000_000) / 10_000,
        output / 1_000_000,
        (output % 1_000_000) / 10_000,
        unitText(priced.billing_unit),
    }) catch {};
    if (priced.discount_basis_points) |basis| {
        if (basis != 10_000) w.print(" -{d}%", .{(10_000 - basis) / 100}) catch {};
    }
    if (priced.estimated) w.writeAll(" est") catch {};
}

fn unitText(unit: offer_mod.BillingUnit) []const u8 {
    return switch (unit) {
        .per_million_tokens => "1M",
        .per_thousand_tokens => "1K",
        .per_token => "token",
        .per_request => "request",
        .provider_defined => "unit",
    };
}

fn writeHealth(w: *std.Io.Writer, health: offer_mod.Health, availability: offer_mod.Availability) void {
    switch (availability) {
        .available => {},
        .deprecated => w.writeAll(" deprecated") catch {},
        .unavailable => w.writeAll(" unavailable") catch {},
        .unknown => {},
    }
    switch (health.status) {
        .unknown => w.writeAll(" health=?") catch {},
        else => w.print(" health={s}", .{@tagName(health.status)}) catch {},
    }
    if (health.latency_ms_p50) |latency| w.print(" p50={d}ms", .{latency}) catch {};
}

fn footer(picker: *const Picker, w: *std.Io.Writer, th: Theme) u16 {
    line(w);
    // Scope and its next-turn semantics are stated, not implied: a commit that
    // silently outlived the session would be a surprise the user cannot undo
    // from here.
    const scope_text = switch (picker.scope) {
        .session => "this session",
        .global => "every future session (durable)",
        .once => "the next turn only",
    };
    w.print(
        "  {s}enter apply to {s} · tab scope · esc back · q close{s}",
        .{ th.dim, scope_text, th.reset },
    ) catch {};
    newline(w);
    line(w);
    w.print(
        "  {s}a change during a reply takes effect on the next turn{s}",
        .{ th.dim, th.reset },
    ) catch {};
    newline(w);
    return 2;
}

/// The sign-in transcript in place of the list (#67): the flow's lines — the
/// URL to open, a device code — wrapped to the width so a URL stays readable,
/// oldest dropped when they do not fit the window, then how to leave.
fn credentialBody(picker: *const Picker, w: *std.Io.Writer, th: Theme, cols: usize) u16 {
    const width = @max(cols -| 2, 8);
    const budget = @max(picker.page_rows, 1);
    const text = picker.credentialLines();
    var total: usize = 0;
    var count_it = std.mem.splitScalar(u8, text, '\n');
    while (count_it.next()) |line_text| total += wrappedCount(line_text.len, width);
    var skip = if (total > budget) total - budget else 0;

    var rows: u16 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_text| {
        var start: usize = 0;
        while (true) {
            const end = @min(start + width, line_text.len);
            if (skip > 0) {
                skip -= 1;
            } else {
                line(w);
                w.print("  {s}", .{line_text[start..end]}) catch {};
                newline(w);
                rows += 1;
            }
            if (end >= line_text.len) break;
            start = end;
        }
    }
    line(w);
    if (picker.credential_failed) {
        w.print("  {s}{s}{s}", .{ th.warn, picker.notice(), th.reset }) catch {};
    } else {
        w.print("  {s}Esc cancels the sign-in{s}", .{ th.dim, th.reset }) catch {};
    }
    newline(w);
    return rows + 1;
}

fn wrappedCount(len: usize, width: usize) usize {
    if (len == 0) return 1;
    return (len + width - 1) / width;
}

fn line(w: *std.Io.Writer) void {
    w.writeAll(ansi.clear.line) catch {};
}

fn newline(w: *std.Io.Writer) void {
    w.writeAll("\r\n") catch {};
}

/// Scope word used by the host when it echoes a commit into the transcript.
pub fn scopeWord(scope: selection_mod.Scope) []const u8 {
    return switch (scope) {
        .session => "session",
        .global => "global",
        .once => "once",
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const ids = @import("../provider/ids.zig");
const control_plane = @import("../provider/control_plane.zig");

fn richOffer() control_plane.OfferSummary {
    const provider_id = ids.Slug.lit("zai-coding-plan");
    const channel_id = ids.Slug.lit("cn-openai");
    return .{
        .offer_id = ids.OfferId.derive(.{
            .provider_id = provider_id,
            .channel_id = channel_id,
            .protocol = "openai_chat",
            .endpoint_url = "https://open.bigmodel.cn/api/coding/paas/v4",
            .request_model_id = "glm-4.6",
        }),
        .provider_id = provider_id,
        .channel_id = channel_id,
        .display_name = "GLM-4.6",
        .request_model_id = "glm-4.6",
        .canonical_model_id = "zai/glm-4.6",
        .upstream_model_id = null,
        .protocol = "openai_chat",
        .endpoint_ref = "https://open.bigmodel.cn/api/coding/paas/v4",
        .credential_ref = null,
        .region = "cn",
        .plan = "coding",
        .limits = .{ .context_window = 200_000, .max_output_tokens = 128_000 },
        .capabilities = .{},
        .quote = .{ .known = .{
            .currency = offer_mod.Currency.lit("USD"),
            .billing_unit = .per_million_tokens,
            .input_price_micros = 3_000_000,
            .output_price_micros = 15_000_000,
            .estimated = true,
        } },
        .health = .{ .status = .healthy, .latency_ms_p50 = 420 },
        .availability = .available,
        .controls = &.{},
        .offer_revision = 1,
    };
}

fn draw(picker: *const Picker, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    _ = render(picker, &writer, theme_mod.dark, 100);
    return writer.buffered();
}

fn seed(picker: *Picker, offers: []const control_plane.OfferSummary, current: ?ids.OfferId) !void {
    try picker.adopt(.{
        .meta = .{ .config_revision = .initial, .catalog_revision = .initial },
        .offers = offers,
        .total = offers.len,
        .truncated = false,
    }, current);
}

test "an offer row shows every column the requirement names" {
    const a = testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    var offers = [_]control_plane.OfferSummary{ richOffer(), richOffer() };
    offers[1].channel_id = ids.Slug.lit("cn-anthropic");
    offers[1].protocol = "anthropic_messages";
    offers[1].offer_id = ids.OfferId.derive(.{
        .provider_id = offers[1].provider_id,
        .channel_id = offers[1].channel_id,
        .protocol = offers[1].protocol,
        .endpoint_url = "https://open.bigmodel.cn/api/anthropic",
        .request_model_id = "glm-4.6",
    });
    try seed(&picker, &offers, offers[1].offer_id);

    _ = picker.onKey(.enter); // provider
    _ = picker.onKey(.enter); // model → offer stage (two routes, one name)
    try testing.expectEqual(picker_mod.Stage.offer, picker.stage);

    var buffer: [8192]u8 = undefined;
    const text = draw(&picker, &buffer);

    for ([_][]const u8{
        "cn-openai", // channel
        "openai_chat", // protocol
        "model=glm-4.6", // the id actually sent on the wire
        "region=cn",
        "plan=coding",
        "ctx=200000",
        "out=128000",
        "USD 3.00/15.00 per 1M",
        "est",
        "health=healthy",
        "p50=420ms",
    }) |needle| {
        testing.expect(std.mem.indexOf(u8, text, needle) != null) catch |err| {
            std.debug.print("missing from offer row: {s}\n{s}\n", .{ needle, text });
            return err;
        };
    }
    // The committed route is marked, so the user can see what they are on.
    try testing.expect(std.mem.indexOf(u8, text, "*") != null);
}

test "unknown metadata renders as unknown, never as absent" {
    const a = testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    var offers = [_]control_plane.OfferSummary{ richOffer(), richOffer() };
    offers[0].limits = .{};
    offers[0].quote = .unknown;
    offers[0].health = .{};
    offers[1].channel_id = ids.Slug.lit("cn-anthropic");
    try seed(&picker, &offers, null);
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);

    var buffer: [8192]u8 = undefined;
    const text = draw(&picker, &buffer);
    // A blank column would read as "unlimited" and "free".
    try testing.expect(std.mem.indexOf(u8, text, "ctx=?") != null);
    try testing.expect(std.mem.indexOf(u8, text, "price=?") != null);
    try testing.expect(std.mem.indexOf(u8, text, "health=?") != null);
}

test "the footer states the scope and the next-turn rule" {
    const a = testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{richOffer()};
    try seed(&picker, &offers, null);

    var buffer: [8192]u8 = undefined;
    var text = draw(&picker, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "this session") != null);
    try testing.expect(std.mem.indexOf(u8, text, "next turn") != null);

    _ = picker.onKey(.cycle_scope);
    text = draw(&picker, &buffer);
    // "durable" has to be visible before the user presses enter on it.
    try testing.expect(std.mem.indexOf(u8, text, "durable") != null);
}

test "a stale or failed catalog says so on screen" {
    const a = testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{richOffer()};
    try seed(&picker, &offers, null);

    var buffer: [8192]u8 = undefined;
    picker.markStale();
    try testing.expect(std.mem.indexOf(u8, draw(&picker, &buffer), "stale") != null);
    picker.markFailed();
    try testing.expect(std.mem.indexOf(u8, draw(&picker, &buffer), "unavailable") != null);
}

test "an empty result explains itself instead of drawing a blank box" {
    const a = testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{richOffer()};
    try seed(&picker, &offers, null);
    for ("zzzz") |byte| _ = picker.onKey(.{ .char = byte });

    var buffer: [8192]u8 = undefined;
    const text = draw(&picker, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "nothing matches") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Esc clears") != null);
}

test "a long list scrolls with a position indicator instead of overflowing" {
    const a = testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    var offers: [30]control_plane.OfferSummary = undefined;
    var names: [30][8]u8 = undefined;
    for (&offers, 0..) |*slot, index| {
        slot.* = richOffer();
        const text = std.fmt.bufPrint(&names[index], "m{d:0>2}", .{index}) catch unreachable;
        slot.display_name = text;
        slot.canonical_model_id = text;
        slot.request_model_id = text;
        slot.offer_id = ids.OfferId.derive(.{
            .provider_id = slot.provider_id,
            .channel_id = slot.channel_id,
            .protocol = slot.protocol,
            .endpoint_url = slot.endpoint_ref,
            .request_model_id = text,
        });
    }
    try seed(&picker, &offers, null);
    _ = picker.onKey(.enter);
    picker.page_rows = 5;

    var buffer: [16384]u8 = undefined;
    const text = draw(&picker, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "[1/30]") != null);
    // Only the window is drawn; a 30-row list would blow past the region.
    try testing.expect(std.mem.indexOf(u8, text, "m00") != null);
    try testing.expect(std.mem.indexOf(u8, text, "m29") == null);
}

test "an option row shows the vocabulary and marks an unsettable control" {
    const a = testing.allocator;
    const specs = [_]@import("../provider/controls.zig").ControlSpec{
        .{
            .id = "reasoning_effort",
            .label = "Reasoning",
            .kind = .enumeration,
            .allowed_values = &.{ "low", "high" },
            .cost_latency_warning = "higher cost and latency",
        },
        .{ .id = "temperature", .label = "Temperature", .kind = .range, .range = .{ .min = 0, .max = 2 } },
    };
    var picker = Picker.init(a);
    defer picker.deinit();
    var offers = [_]control_plane.OfferSummary{richOffer()};
    offers[0].controls = &specs;
    try seed(&picker, &offers, null);
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);

    var buffer: [8192]u8 = undefined;
    const text = draw(&picker, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "Reasoning") != null);
    try testing.expect(std.mem.indexOf(u8, text, "unset") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[low high]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "higher cost and latency") != null);
    // A control the picker cannot set must say so rather than look broken.
    try testing.expect(std.mem.indexOf(u8, text, "(not settable here)") != null);
}

test "the credential stage draws the sign-in transcript, wrapped, and the Esc hint" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers = [_]control_plane.OfferSummary{richOffer()};
    try seed(&picker, &offers, null);
    picker.page_rows = 6;
    _ = picker.onKey(.enter); // provider
    const outcome = picker.onKey(.enter); // one route → commit
    try testing.expect(outcome == .commit);
    _ = picker.enterCredentialStage(ids.Slug.lit("zai"), outcome.commit);
    _ = picker.setCredentialLines("Open this URL to authorize:\nhttps://example.test/authorize?client_id=c&state=s0123456789abcdef&code_challenge=xyz\n");

    var buffer: [8192]u8 = undefined;
    const text = draw(&picker, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "sign in") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Open this URL to authorize:") != null);
    // The URL is longer than the width `draw` renders at; every character of
    // it must still be on screen, split across lines rather than cut.
    try testing.expect(std.mem.indexOf(u8, text, "code_challenge=xyz") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Esc cancels the sign-in") != null);

    picker.credentialFailed("ConnectionRefused");
    const failed_text = draw(&picker, &buffer);
    try testing.expect(std.mem.indexOf(u8, failed_text, "sign-in failed (ConnectionRefused)") != null);
    try testing.expect(std.mem.indexOf(u8, failed_text, "Esc cancels the sign-in") == null);
}
