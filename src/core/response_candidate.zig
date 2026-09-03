//! The candidate-Provider-response boundary (issue #34).
//!
//! One Provider response passes through a lifecycle that AgentLoop already
//! owns end to end:
//!
//! ```text
//! consume StreamEvent
//!   -> assemble text, thinking, reasoning and tool calls
//!   -> publish visible output
//!   -> possibly start tool prefetch
//!   -> build the assistant message
//!   -> commit to or discard from Conversation
//! ```
//!
//! Those steps jointly decide whether a response is ultimately accepted, but
//! until now they existed only as local AgentLoop state. Nothing else could
//! name "the response currently being assembled", so a runtime policy that
//! needed to gate the Conversation commit had no boundary to attach to. The
//! only remaining option was to buffer the whole Provider response somewhere
//! upstream and decide before AgentLoop saw any of it — which is exactly the
//! compensation AgentCore's durable-budget layer was making, at the cost of
//! never delivering a first content event until the response had completed.
//!
//! This module is that boundary, and nothing more. It carries no policy and no
//! accounting: Shared Core stays the single owner of canonical response
//! semantics, and an observer sees what AgentLoop assembled rather than
//! re-deriving it from raw `StreamEvent`s.
//!
//! The contract, in order:
//!
//! - `begin` — a Provider response attempt has started.
//! - `observe` — one canonical increment, *after* AgentLoop normalized it and
//!   (for text) *after* it was published. Returning `.reject` stops the
//!   candidate immediately: the loop consumes no more of the response, starts
//!   no further tool effect, and will discard rather than commit.
//! - `admit` — the last question before the assembled message becomes
//!   Conversation state, for policy that can only decide once the response is
//!   complete.
//! - `settle` — what actually happened to the candidate.
//!
//! `begin` and `settle` are strictly paired: every candidate that begins
//! settles exactly once, on every path including abort, stream error, and
//! rejection. An observer may therefore treat `settle` as the release point
//! for whatever it reserved at `begin`.
//!
//! A rejected candidate is not an error. It is a response the runtime declined
//! to accept, and the loop treats it the way it already treats a discarded
//! partial: the visible output segment closes as `discarded`, no tool effect
//! that has not already started begins, and Conversation is not touched.

const std = @import("std");

/// Identifies one Provider response attempt inside a Run.
///
/// A same-turn re-issue — context-window recovery, a mid-stream transient
/// retry — is a *different* candidate for the same turn, because the response
/// it produces is a different response. Collapsing the two would make an
/// observer that reserves per candidate leak the abandoned one.
pub const CandidateId = struct {
    /// 1-based turn within the Run.
    turn: u32,
    /// 0-based re-issue of that turn.
    attempt: u32,

    pub fn eql(self: CandidateId, other: CandidateId) bool {
        return self.turn == other.turn and self.attempt == other.attempt;
    }
};

/// A completely assembled tool call: the model's arguments after AgentLoop's
/// normalization, and before any effect has been started for it.
pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8,
};

/// One canonical increment of the candidate response.
///
/// Deliberately not a `StreamEvent`: an observer must not have to know how
/// many deltas a provider split a block into, nor repeat AgentLoop's tool-input
/// salvage. Slices are borrowed for the duration of the call.
pub const Increment = union(enum) {
    /// Assistant text that has already been published to consumers.
    text: []const u8,
    /// Reasoning text retained for the next request, never shown as the answer.
    thinking: []const u8,
    /// A provider reasoning item retained verbatim for the next request.
    reasoning_item: []const u8,
    /// A complete tool call, before any tool effect starts.
    tool_use: ToolUse,
};

/// Whether the candidate may continue toward a Conversation commit.
pub const Admission = enum { accept, reject };

/// Why a candidate did not reach Conversation.
pub const Discard = enum {
    /// The user interrupted mid-response.
    aborted,
    /// The stream failed or ended malformed.
    stream_error,
    /// An observer refused it.
    rejected,
    /// Nothing was assembled that was worth committing.
    empty,
    /// The Run failed before the commit-or-discard decision was reached — an
    /// allocation failure between assembly and commit, for instance. It exists
    /// so the `begin`/`settle` pairing is total: an observer that reserved
    /// something at `begin` always gets its release point.
    run_error,
};

pub const Settlement = union(enum) {
    committed,
    discarded: Discard,
};

/// Runtime policy attached to the candidate lifecycle.
///
/// Implementations must be cheap and must not block: every hook runs on the
/// loop's own thread, between reading one stream event and the next.
pub const Observer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin: *const fn (ctx: *anyopaque, candidate: CandidateId) void,
        observe: *const fn (ctx: *anyopaque, candidate: CandidateId, increment: Increment) Admission,
        admit: *const fn (ctx: *anyopaque, candidate: CandidateId) Admission,
        settle: *const fn (ctx: *anyopaque, candidate: CandidateId, settlement: Settlement) void,
    };

    pub fn begin(self: Observer, candidate: CandidateId) void {
        self.vtable.begin(self.ctx, candidate);
    }

    pub fn observe(self: Observer, candidate: CandidateId, increment: Increment) Admission {
        return self.vtable.observe(self.ctx, candidate, increment);
    }

    pub fn admit(self: Observer, candidate: CandidateId) Admission {
        return self.vtable.admit(self.ctx, candidate);
    }

    pub fn settle(self: Observer, candidate: CandidateId, settlement: Settlement) void {
        self.vtable.settle(self.ctx, candidate, settlement);
    }
};

/// Records the lifecycle of every candidate it observes, and can be told to
/// reject at a chosen point. Lives here rather than in a test file because the
/// pairing rule is a property of the boundary, and both Core and AgentCore
/// tests need to assert it.
pub const Recorder = struct {
    pub const Entry = struct {
        candidate: CandidateId,
        kind: Kind,
    };

    pub const Kind = union(enum) {
        began,
        text: usize,
        thinking: usize,
        reasoning_item: usize,
        tool_use: []const u8,
        admitted,
        settled: Settlement,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Reject the Nth `observe` call (0-based). Null never rejects there.
    reject_observe_at: ?usize = null,
    /// Reject at the final commit question instead.
    reject_admit: bool = false,
    observe_calls: usize = 0,

    pub fn deinit(self: *Recorder) void {
        for (self.entries.items) |entry| switch (entry.kind) {
            .tool_use => |name| self.allocator.free(name),
            else => {},
        };
        self.entries.deinit(self.allocator);
    }

    pub fn observer(self: *Recorder) Observer {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Observer.VTable{
        .begin = beginFn,
        .observe = observeFn,
        .admit = admitFn,
        .settle = settleFn,
    };

    fn push(self: *Recorder, candidate: CandidateId, kind: Kind) void {
        self.entries.append(self.allocator, .{ .candidate = candidate, .kind = kind }) catch {};
    }

    fn beginFn(ctx: *anyopaque, candidate: CandidateId) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.push(candidate, .began);
    }

    fn observeFn(ctx: *anyopaque, candidate: CandidateId, increment: Increment) Admission {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const index = self.observe_calls;
        self.observe_calls += 1;
        switch (increment) {
            .text => |bytes| self.push(candidate, .{ .text = bytes.len }),
            .thinking => |bytes| self.push(candidate, .{ .thinking = bytes.len }),
            .reasoning_item => |bytes| self.push(candidate, .{ .reasoning_item = bytes.len }),
            .tool_use => |call| self.push(candidate, .{
                .tool_use = self.allocator.dupe(u8, call.name) catch "",
            }),
        }
        if (self.reject_observe_at) |at| if (at == index) return .reject;
        return .accept;
    }

    fn admitFn(ctx: *anyopaque, candidate: CandidateId) Admission {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.push(candidate, .admitted);
        return if (self.reject_admit) .reject else .accept;
    }

    fn settleFn(ctx: *anyopaque, candidate: CandidateId, outcome: Settlement) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.push(candidate, .{ .settled = outcome });
    }

    pub fn count(self: *const Recorder, needle: std.meta.Tag(Kind)) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            if (std.meta.activeTag(entry.kind) == needle) total += 1;
        }
        return total;
    }

    pub fn settlement(self: *const Recorder) ?Settlement {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.entries.items[index].kind) {
                .settled => |value| return value,
                else => {},
            }
        }
        return null;
    }

    /// True when the observation at `index` is text of exactly `bytes`.
    pub fn textAt(self: *const Recorder, index: usize, bytes: usize) bool {
        if (index >= self.entries.items.len) return false;
        return switch (self.entries.items[index].kind) {
            .text => |len| len == bytes,
            else => false,
        };
    }
};

test "every candidate that begins settles exactly once" {
    var recorder = Recorder{ .allocator = std.testing.allocator };
    defer recorder.deinit();
    const observer = recorder.observer();
    const candidate = CandidateId{ .turn = 1, .attempt = 0 };

    observer.begin(candidate);
    try std.testing.expectEqual(Admission.accept, observer.observe(candidate, .{ .text = "hi" }));
    try std.testing.expectEqual(Admission.accept, observer.admit(candidate));
    observer.settle(candidate, .committed);

    try std.testing.expectEqual(@as(usize, 1), recorder.count(.began));
    try std.testing.expectEqual(@as(usize, 1), recorder.count(.settled));
    try std.testing.expect(recorder.textAt(1, 2));
    try std.testing.expectEqual(Settlement.committed, recorder.settlement().?);
}

test "a same-turn re-issue is a distinct candidate" {
    // Two attempts of turn 3 produce two different responses. Treating them as
    // one would let an observer that reserves per candidate lose track of the
    // abandoned attempt.
    const first = CandidateId{ .turn = 3, .attempt = 0 };
    const second = CandidateId{ .turn = 3, .attempt = 1 };
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(first.eql(.{ .turn = 3, .attempt = 0 }));
}

test "rejection is reported at the observation that refused it" {
    var recorder = Recorder{ .allocator = std.testing.allocator, .reject_observe_at = 1 };
    defer recorder.deinit();
    const observer = recorder.observer();
    const candidate = CandidateId{ .turn = 1, .attempt = 0 };

    observer.begin(candidate);
    try std.testing.expectEqual(Admission.accept, observer.observe(candidate, .{ .text = "first" }));
    try std.testing.expectEqual(Admission.reject, observer.observe(candidate, .{ .text = "second" }));
    observer.settle(candidate, .{ .discarded = .rejected });
    try std.testing.expectEqual(
        Settlement{ .discarded = .rejected },
        recorder.settlement().?,
    );
}
