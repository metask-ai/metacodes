//! Canonical Conversation compaction transaction shared by Run auto-compact
//! and Host manual compact. All provider work happens against an owned preview;
//! the live Conversation changes at exactly one suffix-checked commit point.

const std = @import("std");
const Conversation = @import("conversation.zig").Conversation;
const msg = @import("message.zig");
const compact_summary = @import("compact_summary.zig");
const provider_mod = @import("../api/provider.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const UsageDelta = @import("../api/stream.zig").UsageDelta;

pub const Outcome = enum {
    compacted,
    no_change,
    degraded,
    aborted,
};

pub const Report = struct {
    outcome: Outcome,
    before_tokens: usize,
    after_tokens: usize,
    dropped: usize,
    kept: usize,
    usage: UsageDelta,
    emergency_reduced: bool = false,
};

pub const Estimator = struct {
    ctx: *anyopaque,
    estimate_fn: *const fn (ctx: *anyopaque, conversation: *const Conversation) usize,

    pub fn estimate(self: Estimator, conversation: *const Conversation) usize {
        return self.estimate_fn(self.ctx, conversation);
    }
};

pub const CommitResult = enum {
    committed,
    aborted,
    concurrent_mutation,
};

pub const Committer = struct {
    ctx: *anyopaque,
    commit_fn: *const fn (
        ctx: *anyopaque,
        live: *Conversation,
        suffix: *const Conversation.SuffixSnapshot,
        replacement: *Conversation,
        abort: *const AbortSignal,
    ) CommitResult,

    fn commit(
        self: Committer,
        live: *Conversation,
        suffix: *const Conversation.SuffixSnapshot,
        replacement: *Conversation,
        abort: *const AbortSignal,
    ) CommitResult {
        return self.commit_fn(
            self.ctx,
            live,
            suffix,
            replacement,
            abort,
        );
    }
};

pub const Options = struct {
    keep_recent: usize,
    model_override: ?[]const u8 = null,
    task_anchor: ?[]const u8 = null,
    estimator: ?Estimator = null,
    minimum_saved_percent: usize = 5,
    target_tokens: ?usize = null,
    committer: ?Committer = null,
};

pub const Error = error{
    OutOfMemory,
    ConcurrentMutation,
};

pub fn run(
    allocator: std.mem.Allocator,
    conversation: *Conversation,
    provider: provider_mod.Provider,
    abort: *const AbortSignal,
    options: Options,
) Error!Report {
    const before_tokens = estimate(options.estimator, conversation);
    if (abort.isAborted()) return terminal(.aborted, before_tokens, before_tokens, 0, conversation.activeMessages().len, .{});

    var preview = conversation.cloneForCompactPreview(
        allocator,
        options.keep_recent,
    ) catch return error.OutOfMemory;
    defer preview.deinit();
    const before_active = preview.conversation.activeMessages().len;
    const SummaryContext = struct {
        allocator: std.mem.Allocator,
        provider: provider_mod.Provider,
        abort: *const AbortSignal,
        model_override: ?[]const u8,
        task_anchor: ?[]const u8,
        usage: UsageDelta = .{},
        aborted: bool = false,
        degraded: bool = false,

        fn summarize(self: *@This(), drop_msgs: []const msg.Message) ?[]u8 {
            const result = compact_summary.summarizeAbortable(
                self.allocator,
                self.provider,
                drop_msgs,
                self.model_override,
                self.abort,
                &self.usage,
            ) catch {
                self.aborted = true;
                return null;
            };
            const summary = result orelse {
                self.degraded = true;
                return null;
            };
            return compact_summary.appendTaskAnchor(
                self.allocator,
                summary,
                self.task_anchor,
            );
        }
    };
    var summary_ctx = SummaryContext{
        .allocator = allocator,
        .provider = provider,
        .abort = abort,
        .model_override = options.model_override,
        .task_anchor = options.task_anchor,
    };
    const compact_report = preview.conversation.compactWithSummaryReport(
        options.keep_recent,
        &summary_ctx,
        SummaryContext.summarize,
    ) catch return error.OutOfMemory;
    if (summary_ctx.aborted or abort.isAborted())
        return terminal(
            .aborted,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
    if (compact_report.dropped == 0)
        return terminal(
            .no_change,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );

    var after_tokens = estimate(options.estimator, &preview.conversation);
    if (compact_report.summary_used and !hasMinimumSavings(
        before_tokens,
        after_tokens,
        options.minimum_saved_percent,
    )) {
        return terminal(
            .no_change,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
    }
    if (abort.isAborted())
        return terminal(
            .aborted,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
    var emergency_reduced = false;
    if (options.target_tokens) |target| {
        if (after_tokens > target) {
            const reduction = preview.conversation.microcompactToolResultsByRecentResults(0);
            emergency_reduced = reduction.changed();
            if (emergency_reduced)
                after_tokens = estimate(options.estimator, &preview.conversation);
        }
    }
    const commit_result = if (options.committer) |committer|
        committer.commit(
            conversation,
            &preview.suffix,
            &preview.conversation,
            abort,
        )
    else
        defaultCommit(
            conversation,
            &preview.suffix,
            &preview.conversation,
            abort,
        );
    switch (commit_result) {
        .committed => {},
        .aborted => return terminal(
            .aborted,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        ),
        .concurrent_mutation => return error.ConcurrentMutation,
    }

    var report = terminal(
        if (summary_ctx.degraded) .degraded else .compacted,
        before_tokens,
        after_tokens,
        compact_report.dropped,
        conversation.activeMessages().len,
        summary_ctx.usage,
    );
    report.emergency_reduced = emergency_reduced;
    return report;
}

fn defaultCommit(
    live: *Conversation,
    suffix: *const Conversation.SuffixSnapshot,
    replacement: *Conversation,
    abort: *const AbortSignal,
) CommitResult {
    if (abort.isAborted()) return .aborted;
    return if (live.replaceWithOwnedIfSuffixUnchanged(suffix, replacement))
        .committed
    else
        .concurrent_mutation;
}

fn estimate(estimator: ?Estimator, conversation: *const Conversation) usize {
    return if (estimator) |value|
        value.estimate(conversation)
    else
        conversation.totalTokens();
}

fn terminal(
    outcome: Outcome,
    before_tokens: usize,
    after_tokens: usize,
    dropped: usize,
    kept: usize,
    usage: UsageDelta,
) Report {
    return .{
        .outcome = outcome,
        .before_tokens = before_tokens,
        .after_tokens = after_tokens,
        .dropped = dropped,
        .kept = kept,
        .usage = usage,
    };
}

fn hasMinimumSavings(before: usize, after: usize, percent: usize) bool {
    if (percent == 0) return true;
    if (percent > 100) return false;
    if (before == 0 or after >= before) return false;
    const saved = before - after;
    const whole = (before / 100) * percent;
    const remainder = before % 100;
    const remainder_required = std.math.divCeil(
        usize,
        remainder * percent,
        100,
    ) catch unreachable;
    const required = whole + remainder_required;
    return saved >= required;
}

test "minimum savings is exact and overflow safe" {
    try std.testing.expect(hasMinimumSavings(1000, 949, 5));
    try std.testing.expect(hasMinimumSavings(1000, 950, 5));
    try std.testing.expect(!hasMinimumSavings(1000, 951, 5));
    try std.testing.expect(!hasMinimumSavings(1000, 1000, 5));
    try std.testing.expect(!hasMinimumSavings(0, 0, 5));
    try std.testing.expect(hasMinimumSavings(
        std.math.maxInt(usize),
        0,
        100,
    ));
}
