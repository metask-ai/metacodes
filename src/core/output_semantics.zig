//! Semantic classification of an agent Run's visible output.
//!
//! Requirement: `doc/history/inbound/AGENT_OUTPUT_SEMANTICS_ISSUE.md`.
//!
//! The provider stream can only say "text arrived". Whether that text is an
//! intermediate note the model wrote before calling a tool, the completed
//! answer, or a fragment left over from an interrupted Run is knowledge the
//! agent loop holds — it sees tool calls, max-token continuation, host nudges,
//! aborts and terminal stop reasons. Before this module that knowledge stayed
//! inside the loop and every consumer re-derived it from `text_chunk` plus
//! `stream_done`, which is not a completion signal (a Run emits one per
//! provider stream: per tool round, per continuation, per mid-stream retry).
//!
//! The model here is a **segment**: one provider stream's visible assistant
//! text. A segment opens when the stream opens and closes exactly once, with a
//! `Disposition` the loop assigns at the point it actually knows:
//!
//! ```text
//! text → tool_use                       → commentary  (visible, not the answer)
//! text → end_turn                       → final       (the answer)
//! text → max_tokens → text → end_turn   → continued, final  (one group, one answer)
//! text → abort / budget stop            → partial     (visible, incomplete)
//! text → stream error, rolled back       → discarded   (never reached Conversation)
//! ```
//!
//! `thinking` is already a separate event upstream (`CoreEvent.thinking_chunk`)
//! and is deliberately not a segment: it never becomes visible output and never
//! contributes to a result.
//!
//! Two surfaces expose this:
//!   - `CoreEvent.output_segment_begin` / `.output_segment_end` — streaming
//!     consumers (TUI/web/headless/evaluation) bracket and label text as it
//!     arrives.
//!   - `Ledger` — the direct caller of `agent_loop.run` gets the assembled
//!     final (or partial) text after the Run, instead of guessing from the
//!     Conversation tail.

const std = @import("std");

// Deliberately no SCHEMA_VERSION here. This module has no wire form of its own:
// the classification travels as a `Disposition` on a CoreEvent (versioned with
// the event protocol) and as one `text_kind` string on the headless receipt
// (versioned with that receipt). A constant nothing stamps into anything would
// be decoration claiming a contract that does not exist.

/// Upper bound on text the Ledger retains per Run. Output is not a streaming
/// firehose (a provider response is bounded by max_tokens), but a continuation
/// chain plus a long Run must not grow a host buffer without limit.
pub const MAX_LEDGER_TEXT_BYTES_V1: usize = 4 * 1024 * 1024;

/// What a closed segment turned out to be. Assigned by the agent loop from
/// facts it already has; never inferred by a consumer.
pub const Disposition = enum {
    /// Visible process information: this text was followed by tool calls in
    /// the same turn, or the host rejected it as a premature final and asked
    /// the model to continue. Show it; it is not the answer.
    commentary,
    /// The Run's completed result. Together with any immediately preceding
    /// `.continued` segments of the same group it forms the whole answer.
    final,
    /// Cut off by the provider's token limit and continued by the next
    /// segment of the same group. Not a result on its own.
    continued,
    /// Produced, committed to the Conversation, but never completed — a user
    /// abort, a budget stop, or a host refusal that ends the Run. Safe to
    /// display, never to report as the answer.
    ///
    /// A *stream* API error is `.discarded`, not this: the loop rolls that text
    /// back rather than committing it.
    partial,
    /// Rolled back before reaching the Conversation — a mid-stream failure the
    /// loop re-issues, or context-window recovery. A consumer that buffered
    /// this segment's chunks must drop them. If the retries are exhausted the
    /// Run simply ends with no `.final` segment; the fragment never becomes an
    /// answer either way.
    discarded,

    /// Whether the bytes reached the Conversation and may be shown.
    pub fn isVisible(self: Disposition) bool {
        return self != .discarded;
    }

    /// Whether the segment's bytes belong to the Run's completed result.
    pub fn contributesToFinal(self: Disposition) bool {
        return self == .final or self == .continued;
    }

    /// Whether the segment ends the current logical output.
    ///
    /// `.discarded` does **not**: a rolled-back attempt is retried inside the
    /// same logical output, and any earlier `.continued` bytes of that group are
    /// still in the Conversation. Advancing the group here would strand them in
    /// a group the eventual `.final` no longer belongs to — the event stream and
    /// the Ledger would then disagree about what the answer is.
    pub fn closesGroup(self: Disposition) bool {
        return self != .continued and self != .discarded;
    }
};

/// One closed segment. Pure values — JSON-serializable, safe across a process
/// boundary, no borrowed text.
pub const Segment = struct {
    /// Monotonic within the Run, from 0. A discarded segment consumes an index
    /// so a consumer can tell "rolled back" from "never happened".
    index: u32,
    /// 1-based agent turn the segment belongs to.
    turn: u32,
    /// Continuation group. Segments sharing a group concatenate, in index
    /// order, into one logical output.
    group: u32,
    disposition: Disposition,
    /// Visible bytes the segment produced.
    bytes: u64,
};

/// Run-scoped assembled output. The caller owns it and passes a pointer via
/// `agent_loop.Options.output_ledger`; the loop only appends.
///
/// Recording is best effort by design: an OOM while remembering output must
/// not fail a Run that otherwise succeeded. Loss is reported through
/// `truncated`, never silently.
///
/// **Single-threaded by construction, hence no lock**: a Run writes it from its
/// own thread and it is deliberately never handed to a subagent (a child's
/// output is the parent's tool result, not the parent's answer). Do not share
/// one Ledger across Runs — unlike `file_change.Journal`, it has no mutex.
pub const Ledger = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,
    /// Text of the current group's `.continued` segments, awaiting the
    /// segment that decides what the group was.
    group_buf: std.ArrayList(u8) = .empty,
    /// The completed result, once a `.final` segment closed a group.
    final_buf: std.ArrayList(u8) = .empty,
    /// Visible-but-incomplete output, once a `.partial` segment closed a group.
    partial_buf: std.ArrayList(u8) = .empty,
    has_final: bool = false,
    has_partial: bool = false,
    /// Text or segment metadata was dropped (byte cap or OOM). The retained
    /// text is a prefix of the truth, and callers must not present it as whole.
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator) Ledger {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ledger) void {
        self.segments.deinit(self.allocator);
        self.group_buf.deinit(self.allocator);
        self.final_buf.deinit(self.allocator);
        self.partial_buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// Record one closed segment plus the exact visible bytes it produced.
    pub fn record(self: *Ledger, segment: Segment, text: []const u8) void {
        self.segments.append(self.allocator, segment) catch {
            self.truncated = true;
        };
        switch (segment.disposition) {
            .discarded => {
                // Rolled back: the group so far still stands (it is already in
                // the Conversation); this segment's bytes never were.
            },
            .continued => self.appendCapped(&self.group_buf, text),
            .commentary => self.group_buf.clearRetainingCapacity(),
            .final => {
                self.appendCapped(&self.group_buf, text);
                // Hand the group's storage over instead of copying it: the
                // group is finished, so a second 4 MB buffer would buy nothing.
                std.mem.swap(std.ArrayList(u8), &self.final_buf, &self.group_buf);
                self.group_buf.clearRetainingCapacity();
                self.has_final = true;
                // A completed Run has no partial tail. Enforcing the exclusivity
                // here is what lets `finalText`/`partialText` promise it.
                self.partial_buf.clearRetainingCapacity();
                self.has_partial = false;
            },
            .partial => {
                self.appendCapped(&self.group_buf, text);
                // A Run that already produced a completed result keeps it: a
                // later stray fragment does not demote a finished answer.
                if (self.has_final) {
                    self.group_buf.clearRetainingCapacity();
                    return;
                }
                std.mem.swap(std.ArrayList(u8), &self.partial_buf, &self.group_buf);
                self.group_buf.clearRetainingCapacity();
                self.has_partial = true;
            },
        }
    }

    fn appendCapped(self: *Ledger, buf: *std.ArrayList(u8), text: []const u8) void {
        if (text.len == 0) return;
        const room = MAX_LEDGER_TEXT_BYTES_V1 -| buf.items.len;
        if (room == 0) {
            self.truncated = true;
            return;
        }
        const take = @min(room, text.len);
        if (take < text.len) self.truncated = true;
        buf.appendSlice(self.allocator, text[0..take]) catch {
            self.truncated = true;
        };
    }

    /// The Run's completed result, or null when the Run produced none. Borrowed
    /// from the Ledger; valid until the next `record` or `deinit`.
    pub fn finalText(self: *const Ledger) ?[]const u8 {
        if (!self.has_final) return null;
        return self.final_buf.items;
    }

    /// Visible output from a Run that never completed, or null. Mutually
    /// exclusive with `finalText` — `record` enforces it, so a consumer that
    /// checks `finalText` first can never show a completed answer as partial
    /// (or the reverse).
    pub fn partialText(self: *const Ledger) ?[]const u8 {
        if (!self.has_partial) return null;
        return self.partial_buf.items;
    }

    pub fn countOf(self: *const Ledger, disposition: Disposition) usize {
        var n: usize = 0;
        for (self.segments.items) |s| {
            if (s.disposition == disposition) n += 1;
        }
        return n;
    }
};

/// Per-Run segment bookkeeping owned by the agent loop.
///
/// The loop opens a segment when a provider stream opens and closes it exactly
/// once. `closeIfOpen` is the backstop: any Run exit that forgot to classify
/// leaves the open segment as `.partial`, which is the honest reading of "the
/// Run ended without deciding this output was an answer". Double-close is
/// impossible by construction rather than by discipline.
pub const Tracker = struct {
    next_index: u32 = 0,
    group: u32 = 0,
    open: ?Segment = null,

    pub fn begin(self: *Tracker, turn: u32) Segment {
        const segment = Segment{
            .index = self.next_index,
            .turn = turn,
            .group = self.group,
            .disposition = .partial, // placeholder; `close` decides
            .bytes = 0,
        };
        self.next_index += 1;
        self.open = segment;
        return segment;
    }

    pub fn isOpen(self: *const Tracker) bool {
        return self.open != null;
    }

    /// Close the open segment with its decided disposition. Returns null when
    /// no segment is open, so callers may classify unconditionally.
    pub fn close(self: *Tracker, disposition: Disposition, bytes: u64) ?Segment {
        var segment = self.open orelse return null;
        self.open = null;
        segment.disposition = disposition;
        segment.bytes = bytes;
        if (disposition.closesGroup()) self.group += 1;
        return segment;
    }
};

// ---------------------------------------------------------------------------
// L1 tests
// ---------------------------------------------------------------------------

test "disposition: only final and continued make up a result; only discarded is invisible" {
    try std.testing.expect(Disposition.final.contributesToFinal());
    try std.testing.expect(Disposition.continued.contributesToFinal());
    try std.testing.expect(!Disposition.commentary.contributesToFinal());
    try std.testing.expect(!Disposition.partial.contributesToFinal());

    try std.testing.expect(Disposition.commentary.isVisible());
    try std.testing.expect(Disposition.partial.isVisible());
    try std.testing.expect(!Disposition.discarded.isVisible());
}

test "tracker: a rolled-back segment stays in its continuation group" {
    var t = Tracker{};
    _ = t.begin(1);
    const cut = t.close(.continued, 4).?; // "part" cut off by max_tokens
    _ = t.begin(1);
    const rolled_back = t.close(.discarded, 3).?; // retry died mid-stream
    _ = t.begin(1);
    const answer = t.close(.final, 5).?;

    // All three belong to one logical output; only the final closes it.
    try std.testing.expectEqual(cut.group, rolled_back.group);
    try std.testing.expectEqual(cut.group, answer.group);
    _ = t.begin(2);
    const next = t.close(.commentary, 0).?;
    try std.testing.expect(next.group != answer.group);
}

test "tracker: one open segment, closed once, group advances only on a closing disposition" {
    var t = Tracker{};
    try std.testing.expect(!t.isOpen());

    const s0 = t.begin(1);
    try std.testing.expectEqual(@as(u32, 0), s0.index);
    try std.testing.expect(t.isOpen());
    const closed0 = t.close(.continued, 5).?;
    try std.testing.expectEqual(Disposition.continued, closed0.disposition);
    try std.testing.expectEqual(@as(u32, 0), closed0.group); // continuation keeps the group
    try std.testing.expect(t.close(.final, 0) == null); // no double close

    const s1 = t.begin(1);
    try std.testing.expectEqual(@as(u32, 1), s1.index);
    try std.testing.expectEqual(@as(u32, 0), s1.group); // same continuation group
    const closed1 = t.close(.final, 3).?;
    try std.testing.expectEqual(@as(u32, 0), closed1.group);

    const s2 = t.begin(2);
    try std.testing.expectEqual(@as(u32, 1), s2.group); // final closed the group
}

test "ledger: commentary before tools never enters the final result" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .commentary, .bytes = 14 }, "let me look…");
    ledger.record(.{ .index = 1, .turn = 2, .group = 1, .disposition = .final, .bytes = 4 }, "done");

    try std.testing.expectEqualStrings("done", ledger.finalText().?);
    try std.testing.expect(ledger.partialText() == null);
    try std.testing.expectEqual(@as(usize, 1), ledger.countOf(.commentary));
}

test "ledger: a continuation group concatenates into one result" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .continued, .bytes = 5 }, "part ");
    ledger.record(.{ .index = 1, .turn = 1, .group = 0, .disposition = .continued, .bytes = 4 }, "two ");
    ledger.record(.{ .index = 2, .turn = 1, .group = 0, .disposition = .final, .bytes = 3 }, "end");

    try std.testing.expectEqualStrings("part two end", ledger.finalText().?);
    try std.testing.expectEqual(@as(usize, 2), ledger.countOf(.continued));
}

test "ledger: a continuation group abandoned for a tool call is commentary, not a result" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .continued, .bytes = 4 }, "half");
    ledger.record(.{ .index = 1, .turn = 1, .group = 0, .disposition = .commentary, .bytes = 4 }, "rest");
    ledger.record(.{ .index = 2, .turn = 2, .group = 1, .disposition = .final, .bytes = 2 }, "ok");

    try std.testing.expectEqualStrings("ok", ledger.finalText().?);
}

test "ledger: interrupted output is partial, never final" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .partial, .bytes = 7 }, "half wr");

    try std.testing.expect(ledger.finalText() == null);
    try std.testing.expectEqualStrings("half wr", ledger.partialText().?);
}

test "ledger: final and partial are mutually exclusive in both orders" {
    const a = std.testing.allocator;
    {
        // partial first, then a real answer: the fragment must not linger.
        var ledger = Ledger.init(a);
        defer ledger.deinit();
        ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .partial, .bytes = 4 }, "frag");
        ledger.record(.{ .index = 1, .turn = 2, .group = 1, .disposition = .final, .bytes = 6 }, "answer");
        try std.testing.expectEqualStrings("answer", ledger.finalText().?);
        try std.testing.expect(ledger.partialText() == null);
    }
    {
        // A completed answer is not demoted by a later stray fragment (the
        // run-exit backstop closes any still-open segment as partial).
        var ledger = Ledger.init(a);
        defer ledger.deinit();
        ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .final, .bytes = 6 }, "answer");
        ledger.record(.{ .index = 1, .turn = 1, .group = 1, .disposition = .partial, .bytes = 0 }, "");
        try std.testing.expectEqualStrings("answer", ledger.finalText().?);
        try std.testing.expect(ledger.partialText() == null);
    }
}

test "ledger: a discarded segment contributes no bytes but keeps its index" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .discarded, .bytes = 9 }, "rolled ba");
    ledger.record(.{ .index = 1, .turn = 1, .group = 0, .disposition = .final, .bytes = 5 }, "clean");

    try std.testing.expectEqualStrings("clean", ledger.finalText().?);
    try std.testing.expectEqual(@as(usize, 2), ledger.segments.items.len);
    try std.testing.expectEqual(@as(usize, 1), ledger.countOf(.discarded));
}

test "ledger: exceeding the retention cap reports truncation instead of lying" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    const big = try a.alloc(u8, MAX_LEDGER_TEXT_BYTES_V1 + 16);
    defer a.free(big);
    @memset(big, 'x');

    ledger.record(.{ .index = 0, .turn = 1, .group = 0, .disposition = .final, .bytes = big.len }, big);
    try std.testing.expect(ledger.truncated);
    try std.testing.expectEqual(MAX_LEDGER_TEXT_BYTES_V1, ledger.finalText().?.len);
}

test "segment is JSON-serializable (process-boundary safe)" {
    const a = std.testing.allocator;
    const out = try std.json.Stringify.valueAlloc(a, Segment{
        .index = 2,
        .turn = 3,
        .group = 1,
        .disposition = .final,
        .bytes = 42,
    }, .{});
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"final\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"index\":2") != null);
}
