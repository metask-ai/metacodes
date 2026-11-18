//! Rendering for the cross-UI model picker (issue #16; one screen since the
//! follow-up to #527).
//!
//! Split from the state machine so the drawing can be asserted on without a
//! terminal: every line the user sees is produced here into a plain writer,
//! and covered by tests that read the rendered bytes. The default screen
//! shows what choosing needs — the model, its window, how many routes serve
//! it, which one is in use, who bills it — and keeps protocol names and
//! accounts for the routes listed under the model the cursor is on.

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
/// can account for them in its fixed-region height. No row reaches the last
/// column, so an autowrapping terminal never adds a row the region does not
/// count.
pub fn render(picker: *const Picker, w: *std.Io.Writer, th: Theme, cols: usize) u16 {
    var rows: u16 = 0;
    rows += header(picker, w, th, cols);

    if (picker.stage == .setup) return rows + setupBody(picker, w, th, cols);

    var buffer = Picker.RowBuffer.init(picker.allocator);
    defer buffer.deinit();
    // Rows that cannot be built draw as an empty list, never as a crash.
    const visible = picker.rows(&buffer) catch &.{};
    if (visible.len == 0) {
        line(w);
        w.print("  {s}{s}{s}", .{ th.dim, emptyText(picker), th.reset }) catch {};
        newline(w);
        return rows + 1 + footer(picker, w, th, null);
    }

    const window = @max(picker.page_rows, 1);
    const top = @min(picker.window_top, visible.len -| 1);
    const end = @min(top + window, visible.len);
    const layout = Layout.of(picker, visible[top..end], cols);
    for (visible[top..end], top..) |row, index| {
        rows += drawRow(picker, w, th, layout, row, index == picker.cursor);
    }
    if (end < visible.len or top > 0) {
        // Only a list longer than its window gets this line, and it is where
        // the keys that reach the rest are named: a long list that does not
        // say how to page reads as the whole list. It counts the rows the
        // cursor can stop on; headings are not choices.
        var position: usize = 0;
        var total: usize = 0;
        for (visible, 0..) |row, index| {
            if (!row.focusable()) continue;
            total += 1;
            if (index <= picker.cursor) position = total;
        }
        line(w);
        w.print("  {s}[{d}/{d}] · PgUp/PgDn page · Home/End{s}{s}", .{
            th.dim,
            position,
            total,
            if (picker.stage == .list and picker.filter_len == 0) " · type to filter" else "",
            th.reset,
        }) catch {};
        newline(w);
        rows += 1;
    }
    if (picker.stage == .list) rows += controls(picker, w, th, cols);
    return rows + footer(picker, w, th, visible[@min(picker.cursor, visible.len - 1)]);
}

fn emptyText(picker: *const Picker) []const u8 {
    return switch (picker.status) {
        .loading => "loading models…",
        .failed => "model catalog unavailable — Esc to close",
        .empty => "no models configured",
        else => if (picker.filter_len > 0)
            "nothing matches this filter — Esc clears it"
        else
            "nothing to choose here",
    };
}

fn header(picker: *const Picker, w: *std.Io.Writer, th: Theme, cols: usize) u16 {
    line(w);
    const title = switch (picker.stage) {
        .list => "Model",
        .unconfigured => "Not configured",
        // By pointer: the slug's bytes are inline, and a copy captured by
        // value would be gone before `title` is printed.
        .setup => if (picker.setup) |*setup| setup.provider.slice() else "Provider",
    };
    w.print("  {s}{s}{s}", .{ th.accent, title, th.reset }) catch {};
    var used: usize = 2 + title.len;
    if (picker.stage == .setup) if (picker.setup) |setup| {
        const state = if (setup.sign_in) "not signed in" else "not configured";
        w.print(" {s}{s}{s}", .{ th.dim, state, th.reset }) catch {};
        used += 1 + state.len;
    };
    if (picker.filter_len > 0 and picker.stage != .setup) {
        w.print("  {s}/{s}{s}", .{ th.dim, picker.filter(), th.reset }) catch {};
        used += 3 + picker.filter_len;
    }
    const status: []const u8 = switch (picker.status) {
        // A stale or failed list must say so on the line the user is reading,
        // not only in a log: committing to a route that no longer exists is
        // the failure this warning prevents.
        .stale => " (stale — refreshing)",
        .failed => " (catalog unavailable)",
        .loading => " (loading)",
        else => "",
    };
    if (status.len > 0) {
        const color = switch (picker.status) {
            .stale => th.warn,
            .failed => th.danger,
            else => th.dim,
        };
        w.print("{s}{s}{s}", .{ color, status, th.reset }) catch {};
        used += status.len;
    }
    if (picker.stage == .list) writeScopes(w, th, picker.scope, cols, used);
    newline(w);
    var count: u16 = 1;
    if (picker.notice_len > 0) count += writeWrapped(w, th.warn, th.reset, picker.notice(), cols);
    return count;
}

/// The three scopes, the one Enter applies to bracketed: a commit that
/// silently outlived the session would be a surprise the user cannot undo
/// from here, so the choice is on screen, not only under a key. Right-aligned
/// when the row is wide enough; just the one in use when it is not.
fn writeScopes(w: *std.Io.Writer, th: Theme, scope: selection_mod.Scope, cols: usize, used: usize) void {
    const order = [_]selection_mod.Scope{ .session, .global, .once };
    var full: usize = "apply to".len + "   tab".len + 2;
    for (order) |candidate| full += 2 + scopeLabel(candidate).len;
    const room = cols -| 1;
    if (used + 2 + full <= room) {
        writeSpaces(w, room - used - full);
        w.print("{s}apply to{s}", .{ th.dim, th.reset }) catch {};
        for (order) |candidate| {
            if (candidate == scope) {
                w.print("  {s}[{s}]{s}", .{ th.accent, scopeLabel(candidate), th.reset }) catch {};
            } else {
                w.print("  {s}{s}{s}", .{ th.dim, scopeLabel(candidate), th.reset }) catch {};
            }
        }
        w.print("{s}   tab{s}", .{ th.dim, th.reset }) catch {};
        return;
    }
    const short = 2 + scopeLabel(scope).len + " · tab".len;
    if (used + 2 + short > room) return;
    writeSpaces(w, room - used - short);
    w.print("{s}[{s}]{s}{s} · tab{s}", .{ th.accent, scopeLabel(scope), th.reset, th.dim, th.reset }) catch {};
}

fn scopeLabel(scope: selection_mod.Scope) []const u8 {
    return switch (scope) {
        .session => "this session",
        .global => "from now on",
        .once => "this turn",
    };
}

/// Column widths for the rows in view.
const Layout = struct {
    cols: usize,
    name_width: usize,
    /// A filter is on: the list is flat, and each model names its provider.
    flat: bool,
    /// Some model in view has a price and the row has room for it.
    priced: bool,
    /// The channel column of the route rows: the longest channel in view and
    /// two spaces, so `global-anthropic` does not run into its protocol.
    channel_width: usize,

    fn of(picker: *const Picker, rows: []const Row, cols: usize) Layout {
        var longest: usize = 12;
        var priced = false;
        var channel: usize = 0;
        for (rows) |row| switch (row) {
            .model => |group| {
                const offer = picker.offers.items[group.offer_index];
                longest = @max(longest, textWidth(offer.display_name));
                if (offer.quote.priced() != null) priced = true;
            },
            .route => |route| channel = @max(channel, textWidth(picker.offers.items[route.offer_index].channel_id.slice())),
            else => {},
        };
        const cap = @max(cols / 3, 16);
        return .{
            .cols = cols,
            .name_width = @min(longest + 2, cap),
            .flat = picker.filter_len > 0,
            .priced = priced and cols >= 100,
            .channel_width = @min(channel, 24) + 2,
        };
    }
};

fn drawRow(picker: *const Picker, w: *std.Io.Writer, th: Theme, layout: Layout, row: Row, selected: bool) u16 {
    line(w);
    switch (row) {
        .heading => |heading| {
            const offer = &picker.offers.items[heading.offer_index];
            const note = picker.noteFor(offer.provider_id);
            const name = if (note) |found| found.name() else offer.provider_id.slice();
            const room = layout.cols -| 3;
            const shown = clip(name, room);
            w.print("  {s}{s}{s}", .{ th.accent, shown, th.reset }) catch {};
            // Who bills it, and where its key comes from: switching between
            // groups moves the bill (target state section ten, point 2).
            var tail_buf: [256]u8 = undefined;
            var tail: std.Io.Writer = .fixed(&tail_buf);
            if (note) |found| if (found.originText()) |origin| tail.print(" · {s}", .{origin}) catch {};
            tail.print(" · billed to your {s} account", .{name}) catch {};
            w.print("{s}{s}{s}", .{ th.dim, clip(tail.buffered(), room -| textWidth(shown)), th.reset }) catch {};
        },
        .model => |group| {
            const offer = picker.offers.items[group.offer_index];
            paint(w, th, selected, group.is_current);
            // A model of a provider with no credential is drawn dim: it can
            // be chosen to see where its credential goes, not to switch
            // (#488).
            if (!group.ready) w.print("{s}{s}", .{ th.reset, th.dim }) catch {};
            writePadded(w, clip(offer.display_name, layout.name_width -| 1), layout.name_width);
            w.print("{s}{s}", .{ th.reset, th.dim }) catch {};
            writeWindow(w, offer.limits);
            if (layout.priced) writePrice(w, offer.quote);
            if (group.offer_count > 1) w.print("   {d} routes", .{group.offer_count}) catch {};
            if (layout.flat) {
                var used: usize = 5 + layout.name_width + 6 + (if (group.offer_count > 1) @as(usize, 11) else 0);
                if (layout.priced) used += 22;
                const provider = providerName(picker, offer.provider_id);
                const suffix: []const u8 = if (group.ready) "" else " · not configured";
                w.print("   {s}{s}", .{ clip(provider, layout.cols -| (used + 4 + suffix.len)), suffix }) catch {};
            }
            w.print("{s}", .{th.reset}) catch {};
        },
        .route => |route| {
            const offer = picker.offers.items[route.offer_index];
            paint(w, th, selected, route.is_current);
            w.print("{s}{s}  {s} ", .{ th.reset, th.dim, if (route.last) "└" else "├" }) catch {};
            writePadded(w, offer.channel_id.slice(), layout.channel_width);
            w.print("{s}", .{protocolName(offer.protocol)}) catch {};
            if (offer.region) |region| w.print(" · {s}", .{region}) catch {};
            if (offer.plan) |plan| w.print(" · {s}", .{plan}) catch {};
            // The credential is part of the route identity, so two accounts on
            // one endpoint are two rows and the row has to say which is which.
            if (offer.credential_ref) |ref| w.print(" · account {s}", .{ref.slice()}) catch {};
            if (route.preferred) w.writeAll("   preferred") catch {};
            w.print("{s}", .{th.reset}) catch {};
        },
        .unconfigured => |summary| {
            paint(w, th, selected, false);
            w.print("{s}{s}Not configured · ", .{ th.reset, th.dim }) catch {};
            // Their names when they fit, else how many there are.
            var names_buf: [512]u8 = undefined;
            var names: std.Io.Writer = .fixed(&names_buf);
            var listed: usize = 0;
            for (picker.offers.items, 0..) |*offer, index| {
                if (picker.providerReady(offer.provider_id)) continue;
                const first = for (picker.offers.items[0..index]) |earlier| {
                    if (earlier.provider_id.eql(offer.provider_id)) break false;
                } else true;
                if (!first) continue;
                names.print("{s}{s}", .{ if (listed > 0) ", " else "", offer.provider_id.slice() }) catch {};
                listed += 1;
            }
            const room = layout.cols -| 24;
            if (textWidth(names.buffered()) <= room) {
                w.print("{s}", .{names.buffered()}) catch {};
            } else {
                w.print("{d} providers", .{summary.count}) catch {};
            }
            w.print("{s}", .{th.reset}) catch {};
        },
        .provider => |group| {
            const offer = &picker.offers.items[group.offer_index];
            paint(w, th, selected, false);
            w.print("{s}{s}", .{ th.reset, th.dim }) catch {};
            writePadded(w, offer.provider_id.slice(), 20);
            const setup = picker.setupFor(offer.provider_id);
            if (setup.sign_in) {
                writeSignIn(w, &setup);
            } else if (setup.variable) |variable| {
                w.print("{s} in .env", .{clip(variable, layout.cols -| 40)}) catch {};
            }
            w.print("{s}", .{th.reset}) catch {};
        },
    }
    newline(w);
    return 1;
}

/// The controls of the focused route, a line each: the vocabulary after
/// "default" (unset, the provider's own), the value it would commit
/// bracketed, and the value wanted when this route shows the nearest one it
/// has instead. ←/→ change the first.
fn controls(picker: *const Picker, w: *std.Io.Writer, th: Theme, cols: usize) u16 {
    const offer = picker.focusedOffer() orelse return 0;
    if (offer.controls.len == 0) {
        line(w);
        w.print("  {s}Reasoning effort   — this model takes no level to choose{s}", .{ th.dim, th.reset }) catch {};
        newline(w);
        return 1;
    }
    const first = picker_mod.firstEnumeration(offer.controls);
    var count: u16 = 0;
    for (offer.controls) |spec| {
        line(w);
        w.print("  {s}{s}{s} ", .{ th.primary, spec.label, th.reset }) catch {};
        if (spec.kind != .enumeration or spec.allowed_values.len == 0) {
            w.print("  {s}(not settable here){s}", .{ th.dim, th.reset }) catch {};
            newline(w);
            count += 1;
            continue;
        }
        // The choices, and what is said of them, go on under the first
        // choice where the terminal is too narrow for one row (seven levels
        // and a note do not fit 80 columns). The rows are counted: a row the
        // terminal wrapped on its own would move everything drawn below it.
        const indent = 3 + textWidth(spec.label);
        var row: ChoiceRow = .{ .w = w, .limit = cols -| 1, .indent = indent, .at = indent };
        const shown = picker.effectiveValue(spec);
        row.choice(th, "default", shown == null);
        for (spec.allowed_values) |candidate| {
            row.choice(th, candidate, if (shown) |value| std.mem.eql(u8, value, candidate) else false);
        }
        if (picker.wantedInstead(spec)) |wanted| row.note(th, "(nearest to ", wanted, ")");
        if (first) |walked| if (std.mem.eql(u8, walked.id, spec.id)) row.note(th, "←/→", "", "");
        if (spec.cost_latency_warning) |note| row.note(th, note, "", "");
        newline(w);
        count += 1 + row.more;
    }
    return count;
}

/// One control's choices on as many rows as the width needs, every row past
/// the first indented under the first choice. `limit` is the widest a row
/// may be (the width less one: a row that reaches the last column is wrapped
/// by some terminals).
const ChoiceRow = struct {
    w: *std.Io.Writer,
    limit: usize,
    indent: usize,
    /// Columns written on the current row.
    at: usize,
    /// Nothing written on the current row yet.
    fresh: bool = true,
    /// Rows written after the first.
    more: u16 = 0,

    /// Room for `width` more columns: a new row when this one would
    /// overflow, indented under the first choice, or at the margin when
    /// that leaves too little room. A row that holds nothing yet takes the
    /// item even when it is too wide (it would only leave empty rows).
    fn room(self: *ChoiceRow, width: usize) void {
        defer self.fresh = false;
        if (self.at + width <= self.limit or self.fresh) return;
        newline(self.w);
        line(self.w);
        const margin: usize = if (self.indent + width <= self.limit) self.indent else 2;
        writeSpaces(self.w, margin);
        self.at = margin;
        self.more += 1;
    }

    fn choice(self: *ChoiceRow, th: Theme, text: []const u8, chosen: bool) void {
        // " [x]" and "  x " are both three columns more than the word.
        const width = textWidth(text) + 3;
        self.room(width);
        writeChoice(self.w, th, text, chosen);
        self.at += width;
    }

    fn note(self: *ChoiceRow, th: Theme, before: []const u8, text: []const u8, after: []const u8) void {
        const width = 2 + textWidth(before) + textWidth(text) + textWidth(after);
        self.room(width);
        self.w.print("  {s}{s}{s}{s}{s}", .{ th.dim, before, text, after, th.reset }) catch {};
        self.at += width;
    }
};

fn writeChoice(w: *std.Io.Writer, th: Theme, text: []const u8, chosen: bool) void {
    if (chosen) {
        w.print(" {s}[{s}]{s}", .{ th.accent, text, th.reset }) catch {};
    } else {
        w.print("  {s}{s}{s} ", .{ th.dim, text, th.reset }) catch {};
    }
}

fn footer(picker: *const Picker, w: *std.Io.Writer, th: Theme, under: ?Row) u16 {
    line(w);
    const esc: []const u8 = if (picker.filter_len > 0)
        "esc clear filter"
    else switch (picker.stage) {
        .list => "esc cancel",
        else => "esc back",
    };
    // On a row that applies nothing the footer says what Enter does there
    // instead (#488).
    const instead: []const u8 = switch (picker.stage) {
        .unconfigured => "enter shows where its credential goes",
        else => if (under) |row| switch (row) {
            .unconfigured => "enter lists them",
            .model => |group| if (group.ready) "" else "enter shows where its credential goes",
            .provider => "enter shows where its credential goes",
            else => "",
        } else "",
    };
    if (instead.len > 0) {
        w.print("  {s}{s} · {s} · q close{s}", .{ th.dim, instead, esc, th.reset }) catch {};
    } else {
        const reasoning = if (picker.focusedOffer()) |offer| picker_mod.firstEnumeration(offer.controls) != null else false;
        w.print("  {s}enter apply{s} · tab scope{s} · {s}{s}", .{
            th.dim,
            if (reasoning) " · ←/→ reasoning" else "",
            if (picker.filter_len == 0) " · type to filter" else "",
            esc,
            th.reset,
        }) catch {};
    }
    newline(w);
    line(w);
    w.print(
        "  {s}a change during a reply takes effect on the next turn{s}",
        .{ th.dim, th.reset },
    ) catch {};
    newline(w);
    return 2;
}

/// Where a provider that is not configured gets its credential, in place of
/// `/login` for Metask, whose sign-in is `/login` alone; `/login <id>` for
/// a provider that signs in on its own site (OpenRouter).
fn writeSignIn(w: *std.Io.Writer, setup: *const picker_mod.Setup) void {
    if (setup.provider.eqlText("metask")) {
        w.writeAll("/login") catch {};
    } else {
        w.print("/login {s}", .{setup.provider.slice()}) catch {};
    }
}

/// the list (#488): the variable, this install's `.env` and the guide; for a
/// provider one signs in to (Metask), `/login` first. Nothing to choose and
/// nothing to type, so the only keys named are the ones that leave.
fn setupBody(picker: *const Picker, w: *std.Io.Writer, th: Theme, cols: usize) u16 {
    var rows: u16 = 0;
    if (picker.setup) |setup| {
        const path = if (picker.local_config_path_len > 0) picker.localConfigPath() else ".env";
        var text_buf: [picker_mod.MAX_LOCAL_CONFIG_PATH + 512]u8 = undefined;
        var text: std.Io.Writer = .fixed(&text_buf);
        if (setup.sign_in) {
            text.writeAll("Sign in: ") catch {};
            writeSignIn(&text, &setup);
            text.writeAll("\n") catch {};
        }
        if (setup.variable) |variable| {
            text.print("{s}et {s} in {s}, then restart\n", .{ if (setup.sign_in) "Or s" else "S", variable, path }) catch {};
        }
        if (picker.guide_url.len > 0) text.print("How to: {s}\n", .{picker.guide_url}) catch {};
        const body = std.mem.trimEnd(u8, text.buffered(), "\n");
        if (body.len > 0) rows += writeWrapped(w, th.primary, th.reset, body, cols);
    }
    line(w);
    w.print("  {s}esc back · q close{s}", .{ th.dim, th.reset }) catch {};
    newline(w);
    return rows + 1;
}

/// `text` in `color`, indented two columns: a row per line, each line broken
/// at spaces to fit `cols`, and a word longer than a row (a path, a URL)
/// broken where the row ends. Returns the rows written. No row reaches the
/// last column, so an autowrapping terminal never adds a row the region does
/// not count (a notice naming a variable, a path and a link is longer than
/// any terminal is wide, #483).
fn writeWrapped(w: *std.Io.Writer, color: []const u8, reset: []const u8, text: []const u8, cols: usize) u16 {
    const width = @max(cols -| 3, 8);
    var rows: u16 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |text_line| {
        line(w);
        w.print("  {s}", .{color}) catch {};
        var used: usize = 0;
        var words = std.mem.tokenizeScalar(u8, text_line, ' ');
        while (words.next()) |whole| {
            var word = whole;
            if (used > 0 and used + 1 + word.len > width) {
                w.print("{s}", .{reset}) catch {};
                newline(w);
                rows += 1;
                line(w);
                w.print("  {s}", .{color}) catch {};
                used = 0;
            }
            if (used > 0) {
                w.writeAll(" ") catch {};
                used += 1;
            }
            while (used + word.len > width) {
                const take = utf8Prefix(word, width - used);
                w.writeAll(word[0..take]) catch {};
                word = word[take..];
                w.print("{s}", .{reset}) catch {};
                newline(w);
                rows += 1;
                line(w);
                w.print("  {s}", .{color}) catch {};
                used = 0;
            }
            w.writeAll(word) catch {};
            used += word.len;
        }
        w.print("{s}", .{reset}) catch {};
        newline(w);
        rows += 1;
    }
    return rows;
}

/// The longest prefix of `bytes` of at most `limit` bytes that ends on a
/// character boundary, and never empty: a row too narrow for the first
/// character still takes it rather than looping.
fn utf8Prefix(bytes: []const u8, limit: usize) usize {
    var end = @min(limit, bytes.len);
    while (end > 0 and end < bytes.len and bytes[end] & 0xC0 == 0x80) end -= 1;
    if (end > 0) return end;
    const first = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
    return @min(@as(usize, first), bytes.len);
}

/// `text` cut to at most `width` columns (a character each), at a character
/// boundary.
fn clip(text: []const u8, width: usize) []const u8 {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (columns == width) return text[0..index];
        const step = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index = @min(index + step, text.len);
        columns += 1;
    }
    return text;
}

fn textWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn writePadded(w: *std.Io.Writer, text: []const u8, width: usize) void {
    w.writeAll(text) catch {};
    writeSpaces(w, width -| textWidth(text));
}

fn writeSpaces(w: *std.Io.Writer, count: usize) void {
    for (0..count) |_| w.writeByte(' ') catch {};
}

fn paint(w: *std.Io.Writer, th: Theme, selected: bool, current: bool) void {
    const color = if (selected) th.accent else if (current) th.success else th.primary;
    w.print("  {s}{s}{s} ", .{
        color,
        if (selected) ">" else " ",
        if (current) "*" else " ",
    }) catch {};
}

/// The context window, right-aligned in six columns: `200K`, `1M`. Unknown
/// is printed, not omitted: a blank reads as "no limit", and admission
/// actually fails closed here.
fn writeWindow(w: *std.Io.Writer, limits: offer_mod.EffectiveLimits) void {
    var text_buf: [16]u8 = undefined;
    const text = if (limits.context_window) |window| compactTokens(&text_buf, window) else "?";
    writeSpaces(w, 6 -| text.len);
    w.writeAll(text) catch {};
}

/// Tokens as a window is read: `200K`, `1M` (1,048,576 too), `1.1M`.
fn compactTokens(buf: []u8, tokens: u64) []const u8 {
    if (tokens >= 1_000_000) {
        const tenths = (tokens + 50_000) / 100_000;
        if (tenths % 10 == 0) return std.fmt.bufPrint(buf, "{d}M", .{tenths / 10}) catch "?";
        return std.fmt.bufPrint(buf, "{d}.{d}M", .{ tenths / 10, tenths % 10 }) catch "?";
    }
    if (tokens >= 1_000) return std.fmt.bufPrint(buf, "{d}K", .{(tokens + 500) / 1_000}) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "?";
}

test "a window reads as people say it" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1M", compactTokens(&buf, 1_048_576));
    try testing.expectEqualStrings("1.1M", compactTokens(&buf, 1_050_000));
    try testing.expectEqualStrings("200K", compactTokens(&buf, 200_000));
    try testing.expectEqualStrings("128K", compactTokens(&buf, 128_000));
    try testing.expectEqualStrings("512", compactTokens(&buf, 512));
}

/// The price per million (or per the billing unit), when the catalog says;
/// nothing when it does not.
fn writePrice(w: *std.Io.Writer, quote: offer_mod.Quote) void {
    const priced = quote.priced() orelse return;
    const input = priced.input_price_micros orelse return;
    const output = priced.output_price_micros orelse return;
    w.print("   {s} {d}.{d:0>2}/{d}.{d:0>2} per {s}", .{
        priced.currency.slice(),
        input / 1_000_000,
        (input % 1_000_000) / 10_000,
        output / 1_000_000,
        (output % 1_000_000) / 10_000,
        unitText(priced.billing_unit),
    }) catch {};
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

/// The wire a route speaks, in words.
fn protocolName(protocol: []const u8) []const u8 {
    if (std.mem.eql(u8, protocol, "anthropic_messages")) return "Anthropic Messages API";
    if (std.mem.eql(u8, protocol, "openai_chat")) return "OpenAI Chat API";
    if (std.mem.eql(u8, protocol, "openai_responses")) return "OpenAI Responses API";
    if (std.mem.eql(u8, protocol, "gemini_generate")) return "Gemini API";
    return protocol;
}

fn providerName(picker: *const Picker, provider: picker_mod.Slug) []const u8 {
    if (picker.noteFor(provider)) |note| return note.name();
    for (picker.offers.items) |*offer| {
        if (offer.provider_id.eql(provider)) return offer.provider_id.slice();
    }
    return "";
}

fn line(w: *std.Io.Writer) void {
    w.writeAll(ansi.clear.line) catch {};
}

fn newline(w: *std.Io.Writer) void {
    w.writeAll("\r\n") catch {};
}

/// How the host's line after a commit says the scope: "switched to glm-5.3
/// for this session".
pub fn scopePhrase(scope: selection_mod.Scope) []const u8 {
    return switch (scope) {
        .session => "for this session",
        .global => "from now on",
        .once => "for this turn",
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const ids = @import("../provider/ids.zig");
const control_plane = @import("../provider/control_plane.zig");
const controls_mod = @import("../provider/controls.zig");

fn offerOf(provider: []const u8, channel: []const u8, model: []const u8, protocol: []const u8) control_plane.OfferSummary {
    const provider_id = ids.Slug.parse(provider) catch unreachable;
    const channel_id = ids.Slug.parse(channel) catch unreachable;
    return .{
        .offer_id = ids.OfferId.derive(.{
            .provider_id = provider_id,
            .channel_id = channel_id,
            .protocol = protocol,
            .endpoint_url = "https://example.invalid",
            .request_model_id = model,
        }),
        .provider_id = provider_id,
        .channel_id = channel_id,
        .display_name = model,
        .request_model_id = model,
        .canonical_model_id = null,
        .upstream_model_id = null,
        .protocol = protocol,
        .endpoint_ref = "https://example.invalid",
        .credential_ref = null,
        .region = null,
        .plan = null,
        .limits = .{ .context_window = 200_000 },
        .capabilities = .{},
        .quote = .unknown,
        .health = .{},
        .availability = .available,
        .controls = &.{},
        .offer_revision = 1,
    };
}

fn seed(picker: *Picker, offers: []const control_plane.OfferSummary, current: ?ids.OfferId) !void {
    try picker.adopt(.{
        .meta = .{ .config_revision = .initial, .catalog_revision = .initial },
        .offers = offers,
        .total = offers.len,
        .truncated = false,
    }, current);
    picker.restart();
}

fn drawAt(picker: *const Picker, buffer: []u8, cols: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    _ = render(picker, &writer, theme_mod.dark, cols);
    return writer.buffered();
}

/// The rendered rows with the escape sequences taken out.
fn visibleRows(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.splitSequence(u8, text, "\r\n");
    while (rows.next()) |raw| {
        var plain: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == 0x1b and index + 1 < raw.len and raw[index + 1] == '[') {
                index += 2;
                while (index < raw.len and (raw[index] < 0x40 or raw[index] > 0x7e)) index += 1;
                index += 1;
                continue;
            }
            try plain.append(arena, raw[index]);
            index += 1;
        }
        try out.append(arena, plain.items);
    }
    // The last "\r\n" ends the last row; nothing follows it.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

fn screen(arena: std.mem.Allocator, picker: *const Picker, cols: usize) ![]const u8 {
    const buffer = try arena.alloc(u8, 32 * 1024);
    const rows = try visibleRows(arena, drawAt(picker, buffer, cols));
    return std.mem.join(arena, "\n", rows);
}

const REASONING = [_]controls_mod.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &.{ "low", "medium", "high", "max" },
}};

/// Every level a reasoning control may name.
const ALL_LEVELS = [_]controls_mod.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &.{ "none", "minimal", "low", "medium", "high", "xhigh", "max" },
}};

test "a heading per provider says where its key comes from and who bills it; a row per model shows its window and routes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var big = offerOf("deepseek", "default", "DeepSeek V4 Pro", "openai_chat");
    big.limits = .{ .context_window = 1_048_576 };
    var other = offerOf("deepseek", "anthropic", "DeepSeek V4 Pro", "anthropic_messages");
    other.limits = big.limits;
    const offers = [_]control_plane.OfferSummary{ offerOf("metask", "default", "glm-5.3-flash", "anthropic_messages"), big, other };
    try seed(&picker, &offers, offers[0].offer_id);
    const notes = [_]picker_mod.ProviderNote{
        picker_mod.ProviderNote.init(ids.Slug.lit("metask"), "Metask", .signed_in),
        picker_mod.ProviderNote.init(ids.Slug.lit("deepseek"), "DeepSeek", .local_config),
    };
    try picker.setReadiness(&.{ true, true, true }, &.{}, &notes);
    const text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "Metask · signed in · billed to your Metask account") != null);
    try testing.expect(std.mem.indexOf(u8, text, "DeepSeek · key from .env · billed to your DeepSeek account") != null);
    try testing.expect(std.mem.indexOf(u8, text, ">* glm-5.3-flash") != null);
    try testing.expect(std.mem.indexOf(u8, text, "200K") != null);
    try testing.expect(std.mem.indexOf(u8, text, "DeepSeek V4 Pro") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1M   2 routes") != null);
    // No protocol names or unknowns on the default screen.
    try testing.expect(std.mem.indexOf(u8, text, "openai_chat") == null);
    try testing.expect(std.mem.indexOf(u8, text, "price=?") == null);
    try testing.expect(std.mem.indexOf(u8, text, "health=?") == null);
}

test "a channel longer than the column does not run into its protocol" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{
        offerOf("kimi", "cn-openai", "kimi-k3.1-pro", "openai_chat"),
        offerOf("kimi", "global-anthropic", "kimi-k3.1-pro", "anthropic_messages"),
    };
    try seed(&picker, &offers, null);
    const text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "└ global-anthropic  Anthropic Messages API") != null);
    try testing.expect(std.mem.indexOf(u8, text, "├ cn-openai         OpenAI Chat API") != null);
}

test "the routes of the model under the cursor are listed under it, in words, the preferred one marked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{
        offerOf("deepseek", "default", "deepseek-v4-pro", "openai_chat"),
        offerOf("deepseek", "anthropic", "deepseek-v4-pro", "anthropic_messages"),
    };
    try seed(&picker, &offers, null);
    const text = try screen(arena, &picker, 120);
    // The channel column is as wide as the longest channel in view, and two.
    try testing.expect(std.mem.indexOf(u8, text, "├ default    OpenAI Chat API   preferred") != null);
    try testing.expect(std.mem.indexOf(u8, text, "└ anthropic  Anthropic Messages API") != null);
}

test "unknown limits render as unknown, never as absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offer = offerOf("metask", "default", "mystery", "anthropic_messages");
    offer.limits = .{};
    const offers = [_]control_plane.OfferSummary{offer};
    try seed(&picker, &offers, null);
    const text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "mystery") != null);
    try testing.expect(std.mem.indexOf(u8, text, "     ?") != null);
}

test "the header names the three scopes, the one Enter applies to bracketed; the footer the keys and the next-turn rule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offer = offerOf("metask", "default", "glm-5.3", "anthropic_messages");
    offer.controls = &REASONING;
    const offers = [_]control_plane.OfferSummary{offer};
    try seed(&picker, &offers, null);
    var text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "apply to  [this session]  from now on  this turn   tab") != null);
    try testing.expect(std.mem.indexOf(u8, text, "enter apply · ←/→ reasoning · tab scope · type to filter · esc cancel") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a change during a reply takes effect on the next turn") != null);
    _ = picker.onKey(.cycle_scope);
    text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "this session  [from now on]  this turn") != null);
}

test "a stale or failed catalog says so on screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{offerOf("metask", "default", "m", "anthropic_messages")};
    try seed(&picker, &offers, null);
    picker.markStale();
    try testing.expect(std.mem.indexOf(u8, try screen(arena, &picker, 120), "(stale — refreshing)") != null);
    picker.markFailed();
    try testing.expect(std.mem.indexOf(u8, try screen(arena, &picker, 120), "(catalog unavailable)") != null);
}

test "the reasoning line shows default and the vocabulary, the level shown bracketed, and the one wanted when another is shown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const short = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning effort",
        .kind = .enumeration,
        .allowed_values = &.{ "low", "high" },
    }};
    var wide = offerOf("metask", "default", "glm-5.3", "anthropic_messages");
    wide.controls = &REASONING;
    var narrow = offerOf("metask", "default", "hy4", "anthropic_messages");
    narrow.controls = &short;
    const plain = offerOf("metask", "default", "no-levels", "anthropic_messages");
    const offers = [_]control_plane.OfferSummary{ wide, narrow, plain };
    try seed(&picker, &offers, null);
    var text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "Reasoning effort  [default]  low   medium   high   max   ←/→") != null);
    picker.presetControl("reasoning_effort", "max");
    text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "[max]") != null);
    _ = picker.onKey(.down);
    text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "[high]  (nearest to max)") != null);
    _ = picker.onKey(.down);
    text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "this model takes no level to choose") != null);
    // Without a level to change, the footer does not offer ←/→.
    try testing.expect(std.mem.indexOf(u8, text, "←/→ reasoning") == null);
}

test "providers with no credential are one dim line; Enter lists them; the footer says what Enter does there (#488)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{
        offerOf("deepseek", "default", "deepseek-v4-pro", "openai_chat"),
        offerOf("openai", "default", "gpt-6", "openai_chat"),
        offerOf("gemini", "default", "gemini-3", "gemini_generate"),
    };
    try seed(&picker, &offers, null);
    const setups = [_]picker_mod.Setup{.{ .provider = ids.Slug.lit("openai"), .variable = "OPENAI_API_KEY" }};
    try picker.setReadiness(&.{ true, false, false }, &setups, &.{});
    _ = picker.onKey(.down);
    var text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "Not configured · openai, gemini") != null);
    try testing.expect(std.mem.indexOf(u8, text, "enter lists them · esc cancel · q close") != null);
    _ = picker.onKey(.enter);
    text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "Not configured") != null);
    try testing.expect(std.mem.indexOf(u8, text, "OPENAI_API_KEY in .env") != null);
    try testing.expect(std.mem.indexOf(u8, text, "enter shows where its credential goes · esc back · q close") != null);
}

test "the setup stage shows the variable, this install's .env and the guide, and no way to type a key (#488)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{offerOf("kimi", "default", "k3", "openai_chat")};
    try seed(&picker, &offers, null);
    picker.setLocalConfig("/home/u/.local/opt/metacodes/state/.env", "https://example.invalid/guide");
    picker.enterSetup(.{ .provider = ids.Slug.lit("kimi"), .variable = "MOONSHOT_API_KEY" });
    const text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "kimi not configured") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Set MOONSHOT_API_KEY in /home/u/.local/opt/metacodes/state/.env, then restart") != null);
    try testing.expect(std.mem.indexOf(u8, text, "How to: https://example.invalid/guide") != null);
    try testing.expect(std.mem.indexOf(u8, text, "esc back · q close") != null);
}

test "a filter lists the matches flat, each naming its provider" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{
        offerOf("metask", "default", "glm-5.3", "anthropic_messages"),
        offerOf("zai-coding-plan", "default", "glm-4.6", "anthropic_messages"),
    };
    try seed(&picker, &offers, null);
    try picker.setReadiness(&.{ true, false }, &.{}, &.{});
    for ("glm") |byte| _ = picker.onKey(.{ .char = byte });
    const text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "Model  /glm") != null);
    try testing.expect(std.mem.indexOf(u8, text, "metask") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zai-coding-plan · not configured") != null);
    try testing.expect(std.mem.indexOf(u8, text, "billed to") == null);
}

test "a long list scrolls with a position indicator that counts models, not headings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var names: [30][4]u8 = undefined;
    var offers: [30]control_plane.OfferSummary = undefined;
    for (&offers, 0..) |*slot, index| {
        const id = std.fmt.bufPrint(&names[index], "m{d:0>2}", .{index}) catch unreachable;
        slot.* = offerOf("metask", "default", id, "anthropic_messages");
    }
    try seed(&picker, &offers, null);
    picker.page_rows = 6;
    _ = picker.onKey(.end);
    const text = try screen(arena, &picker, 120);
    try testing.expect(std.mem.indexOf(u8, text, "[30/30] · PgUp/PgDn page · Home/End · type to filter") != null);
    try testing.expect(std.mem.indexOf(u8, text, "m29") != null);
    try testing.expect(std.mem.indexOf(u8, text, "m00") == null);
}

test "every row fits an 80-column terminal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var long = offerOf("metask", "default", "DeepSeek-V4.1-Flash-1017-with-a-much-longer-name-than-usual", "anthropic_messages");
    long.controls = &REASONING;
    const offers = [_]control_plane.OfferSummary{
        long,
        offerOf("deepseek", "default", "deepseek-v4-pro", "openai_chat"),
        offerOf("deepseek", "anthropic", "deepseek-v4-pro", "anthropic_messages"),
        offerOf("openai", "default", "gpt-6", "openai_chat"),
        offerOf("gemini", "default", "gemini-3", "gemini_generate"),
        offerOf("zai-coding-plan", "default", "glm-4.6", "anthropic_messages"),
        offerOf("kimi-code", "default", "k3", "openai_chat"),
        offerOf("qwen", "default", "qwen3", "openai_chat"),
    };
    try seed(&picker, &offers, offers[0].offer_id);
    const notes = [_]picker_mod.ProviderNote{
        picker_mod.ProviderNote.init(ids.Slug.lit("metask"), "Metask", .signed_in),
        picker_mod.ProviderNote.init(ids.Slug.lit("deepseek"), "DeepSeek", .environment),
    };
    try picker.setReadiness(&.{ true, true, true, false, false, false, false, false }, &.{}, &notes);
    picker.presetControl("reasoning_effort", "high");
    const states = [_][]const u8{ "", "g", "glm" };
    for (states) |typed| {
        picker.restart();
        picker.presetControl("reasoning_effort", "high");
        for (typed) |byte| _ = picker.onKey(.{ .char = byte });
        for (0..4) |_| {
            const buffer = try arena.alloc(u8, 32 * 1024);
            for (try visibleRows(arena, drawAt(&picker, buffer, 80))) |row| {
                if (textWidth(row) >= 80) {
                    std.debug.print("too wide ({d}): {s}\n", .{ textWidth(row), row });
                    return error.RowTooWide;
                }
            }
            _ = picker.onKey(.down);
        }
    }
}

test "all seven reasoning levels and a note fit an 80-column terminal, and the rows they take are counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var seven = offerOf("openai", "default", "gpt-6", "openai_chat");
    seven.controls = &ALL_LEVELS;
    var four = offerOf("metask", "default", "glm-5.3", "anthropic_messages");
    four.controls = &REASONING;
    const offers = [_]control_plane.OfferSummary{ seven, four };
    try seed(&picker, &offers, offers[0].offer_id);
    // The whole screen at 80 and 120 columns; the reasoning rows alone at
    // narrower widths. On the seven-level model, then on the four-level one,
    // where the level wanted (minimal) is not offered and a note says so.
    for ([_]usize{ 80, 120, 60, 40 }) |cols| {
        picker.restart();
        picker.presetControl("reasoning_effort", "minimal");
        for (0..2) |_| {
            const buffer = try arena.alloc(u8, 32 * 1024);
            var writer = std.Io.Writer.fixed(buffer);
            const counted = if (cols >= 80)
                render(&picker, &writer, theme_mod.dark, cols)
            else
                controls(&picker, &writer, theme_mod.dark, cols);
            const drawn = writer.buffered();
            // Every row ends with CRLF: the rows counted are the rows drawn.
            try testing.expectEqual(@as(usize, counted), std.mem.count(u8, drawn, "\r\n"));
            const rows = try visibleRows(arena, drawn);
            for (rows) |row| {
                if (textWidth(row) >= cols) {
                    std.debug.print("too wide at {d} ({d}): {s}\n", .{ cols, textWidth(row), row });
                    return error.RowTooWide;
                }
            }
            // Nothing is dropped: every level is on the screen.
            const text = try std.mem.join(arena, "\n", rows);
            const offer = picker.focusedOffer().?;
            for (offer.controls[0].allowed_values) |level| try testing.expect(std.mem.indexOf(u8, text, level) != null);
            _ = picker.onKey(.down);
        }
    }
}

test "a notice of several lines is drawn a row per line, every row inside the width (#483)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{offerOf("metask", "default", "m", "anthropic_messages")};
    try seed(&picker, &offers, null);
    picker.setNotice("no credential for kimi\nSet MOONSHOT_API_KEY in /a/very/long/path/that/keeps/going/and/going/state/.env, then restart\nHow to: https://example.invalid/a/long/guide", .{});
    const buffer = try arena.alloc(u8, 32 * 1024);
    const rows = try visibleRows(arena, drawAt(&picker, buffer, 40));
    var notice_rows: usize = 0;
    for (rows) |row| {
        const in_notice = std.mem.indexOf(u8, row, "kimi") != null or std.mem.indexOf(u8, row, "MOONSHOT") != null or
            std.mem.indexOf(u8, row, "/a/very") != null or std.mem.indexOf(u8, row, "How to") != null;
        if (!in_notice) continue;
        try testing.expect(textWidth(row) < 40);
        notice_rows += 1;
    }
    try testing.expect(notice_rows >= 3);
}

test "a row too narrow for a character breaks after it, never inside it" {
    try testing.expectEqual(@as(usize, 3), utf8Prefix("你好", 1));
    try testing.expectEqual(@as(usize, 3), utf8Prefix("你好", 4));
    try testing.expectEqualStrings("你", clip("你好", 1));
}

test "an empty result explains itself instead of drawing a blank box" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]control_plane.OfferSummary{offerOf("metask", "default", "glm-5.3", "anthropic_messages")};
    try seed(&picker, &offers, null);
    for ("zzz") |byte| _ = picker.onKey(.{ .char = byte });
    try testing.expect(std.mem.indexOf(u8, try screen(arena, &picker, 120), "nothing matches this filter — Esc clears it") != null);
}
