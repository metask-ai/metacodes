//! Run-scoped durable-state compaction control (issue #430).
//!
//! The shared AgentLoop owns *when* a Conversation may be compacted (the safe
//! boundaries before sampling and after tool results, and the same-turn
//! recovery after a request was refused) and the compact kernel owns *how*.
//! An embedding layer that owns durable state — AgentCore's checkpoint budget
//! — owns neither, but it must be able to:
//!
//! - ask for compaction because its own capacity is under pressure, not only
//!   the model's token window (`wantsCompaction`);
//! - treat the provider traffic of a compaction as maintenance rather than
//!   Conversation growth (`begin` .. `settle`);
//! - refuse a replacement that does not fit its budget at the kernel's single
//!   commit point (`allowCommit`);
//! - recompute its accounting from the state that compaction produced
//!   (`settle` with `.committed`);
//! - record its own terminal refusal when the loop gives up on a request the
//!   owner deferred (`abandonDeferred`), so the Run ends with the owner's
//!   budget outcome rather than an unexplained provider failure.
//!
//! This module is that seam and nothing more: no policy and no accounting.
//! A Run without a control behaves exactly as before.
//!
//! Contract, per attempt the loop considers:
//!
//! - `begin` is called once an attempt is admitted (something is compactable)
//!   and precedes any provider request the attempt makes;
//! - `allowCommit` is called at most once, at the replacement linearization
//!   point, after the summary request finished;
//! - `settle` is called exactly once per attempt that was admitted, and also
//!   for a durable-capacity attempt that found nothing to compact, so the
//!   owner can stop asking. A `committed` settlement carries the live
//!   Conversation as it now is.
//! - A refused `allowCommit` is the owner's terminal: the attempt reports
//!   `refused` (not a cancellation) and the Run stops the way a request the
//!   owner refused stops. The owner has already recorded why.
//! - `abandonDeferred` is called at most once per deferred request, when the
//!   loop stops instead of re-issuing it (the recovery compaction failed, or
//!   the turn's recovery bound is spent).
//!
//! With a control installed the loop never mutates durable Conversation
//! history outside the kernel's guarded commit: the context-window recovery
//! does not fall back to trimming the oldest messages, and the stale
//! tool-result microcompaction and tool-result truncation passes do not run
//! (both rewrite committed tool results in place). The only reductions are
//! the ones the kernel applies to its preview, which reach durable state
//! through `allowCommit`.

const std = @import("std");
const Conversation = @import("conversation.zig").Conversation;

/// Why the loop is compacting. Only the owner of durable state can tell its
/// own pressure apart from the model window's.
pub const Trigger = enum {
    /// The token window: the pre-sampling / post-tool threshold, or the
    /// provider refused the request as too long.
    context_window,
    /// The owner's durable capacity: `wantsCompaction`, or a request the
    /// owner deferred with `error.DurableCapacityExceeded`.
    durable_capacity,
};

pub const Settlement = union(enum) {
    /// The kernel replaced the Conversation. The pointer is the live state.
    committed: *const Conversation,
    /// The attempt ended without a replacement: the savings gate refused it,
    /// the summary failed or was refused, the commit was refused, or the Run
    /// was cancelled while it ran.
    not_committed,
    /// A durable-capacity attempt found no history older than the retained
    /// suffix; nothing was requested from the provider.
    nothing_to_compact,
};

/// A Provider decorator that owns durable admission returns this, before any
/// network I/O, when a request does not fit durable capacity but compaction
/// might make it fit. The loop answers with a bounded durable-capacity
/// compaction and re-issues the same turn; when the owner can no longer
/// relieve capacity it refuses with its own terminal error instead.
pub const Error = error{DurableCapacityExceeded};

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        wantsCompaction: *const fn (ctx: *anyopaque) bool,
        begin: *const fn (ctx: *anyopaque, trigger: Trigger) void,
        allowCommit: *const fn (ctx: *anyopaque, replacement: *const Conversation) bool,
        settle: *const fn (ctx: *anyopaque, trigger: Trigger, settlement: Settlement) void,
        abandonDeferred: *const fn (ctx: *anyopaque) void,
    };

    pub fn wantsCompaction(self: Control) bool {
        return self.vtable.wantsCompaction(self.ctx);
    }

    pub fn begin(self: Control, trigger: Trigger) void {
        self.vtable.begin(self.ctx, trigger);
    }

    pub fn allowCommit(self: Control, replacement: *const Conversation) bool {
        return self.vtable.allowCommit(self.ctx, replacement);
    }

    pub fn settle(self: Control, trigger: Trigger, settlement: Settlement) void {
        self.vtable.settle(self.ctx, trigger, settlement);
    }

    /// The loop stops a request the owner deferred with
    /// `error.DurableCapacityExceeded` instead of re-issuing it. The owner
    /// records the refusal the re-issued request would have met.
    pub fn abandonDeferred(self: Control) void {
        self.vtable.abandonDeferred(self.ctx);
    }
};

/// Test double that records the calls and answers from fields.
pub const Recorder = struct {
    wants: bool = false,
    allow: bool = true,
    begins: u32 = 0,
    allow_calls: u32 = 0,
    committed: u32 = 0,
    not_committed: u32 = 0,
    nothing: u32 = 0,
    abandoned: u32 = 0,
    last_trigger: ?Trigger = null,
    /// `wants` is cleared after this many `wantsCompaction` answers of true.
    wants_budget: u32 = std.math.maxInt(u32),

    pub fn control(self: *Recorder) Control {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Control.VTable{
        .wantsCompaction = wantsFn,
        .begin = beginFn,
        .allowCommit = allowFn,
        .settle = settleFn,
        .abandonDeferred = abandonFn,
    };

    fn cast(raw: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(raw));
    }

    fn wantsFn(raw: *anyopaque) bool {
        const self = cast(raw);
        if (!self.wants or self.wants_budget == 0) return false;
        self.wants_budget -= 1;
        return true;
    }

    fn beginFn(raw: *anyopaque, trigger: Trigger) void {
        const self = cast(raw);
        self.begins += 1;
        self.last_trigger = trigger;
    }

    fn allowFn(raw: *anyopaque, _: *const Conversation) bool {
        const self = cast(raw);
        self.allow_calls += 1;
        return self.allow;
    }

    fn settleFn(raw: *anyopaque, trigger: Trigger, settlement: Settlement) void {
        const self = cast(raw);
        self.last_trigger = trigger;
        switch (settlement) {
            .committed => self.committed += 1,
            .not_committed => self.not_committed += 1,
            .nothing_to_compact => self.nothing += 1,
        }
    }

    fn abandonFn(raw: *anyopaque) void {
        cast(raw).abandoned += 1;
    }
};
